;;; package-update.scm --- packages follow the compos release; an API break files its fix.
;;;
;;; Packages have no versions of their own: a compos release is the
;;; heartbeat. CI vouches for one commit of each compos-dev package, the
;;; one whose tests passed with the release, in priv/standard.lock, and
;;; package-follow-release! moves the pins of packages.lock to those
;;; commits on the first boot of a new release. A package from the user's
;;; own source follows its newest commit.
;;;
;;; An update fails forward: it never stops at a break. When it raises a
;;; package's :major or drops public names, package-fail-forward! finds
;;; every use of those names in the user's own code, files a todo with the
;;; plan and starts a chat on it; the user reviews the fix. Hold and
;;; rollback are the escape hatch, not the default.

(require 'package)

(domain! 'packages)
(effects! '(pure))

(defcustom 'package-fix-group #f
  "The group a fix-forward todo goes in, by name or id; #f is the group you are in, else the most recent one"
  'group 'packages)

(defcustom 'package-fix-project "general"
  "The todo project a fix-forward todo goes in" 'group 'packages)

(defcustom 'package-fix-start-chat #t
  "#t starts a chat on a fix-forward todo as soon as it is filed; #f leaves it in the inbox"
  'group 'packages 'type 'boolean)

(define (package-update--dedup xs)
  (let loop ((xs xs) (acc '()))
    (cond ((null? xs) (reverse acc))
          ((member (car xs) acc) (loop (cdr xs) acc))
          (else (loop (cdr xs) (cons (car xs) acc))))))

(define (package-update--short c)
  (if (and (string? c) (> (string-length c) 7)) (substring c 0 7) (or c "-")))

(define (package-update--sym-char? c)
  (or (char-alphabetic? c) (char-numeric? c)
      (and (string-search (list->string (list c)) "-_!?*<>=/+:.%&$^~") #t)))

(define (package-update--has? line name)
  ;; NAME stands in LINE as a whole symbol
  (let ((n (string-length name)) (len (string-length line)))
    (let scan ((from 0))
      (let ((at (string-search name line from)))
        (and at
             (or (and (or (= at 0) (not (package-update--sym-char? (string-ref line (- at 1)))))
                      (or (= (+ at n) len) (not (package-update--sym-char? (string-ref line (+ at n))))))
                 (scan (+ at 1))))))))

(define (package-update-uses-in text name)
  "(package-update-uses-in TEXT NAME) -- where NAME stands as a whole symbol in TEXT, as ((LINE TEXT) ...)"
  (let loop ((ls (string-split text "\n")) (i 1) (acc '()))
    (if (null? ls)
        (reverse acc)
        (loop (cdr ls) (+ i 1)
              (if (package-update--has? (car ls) name) (cons (list i (string-trim (car ls))) acc) acc)))))

(define (package-update--form-names f)
  (cond ((not (pair? f)) '())
        ((eq? (car f) 'begin) (apply append (map package-update--form-names (cdr f))))
        ((not (pair? (cdr f))) '())
        ((and (memq (car f) '(public! defcustom)) (pair? (cadr f)) (eq? (car (cadr f)) 'quote)
              (symbol? (cadr (cadr f))))
         (list (symbol->string (cadr (cadr f)))))
        ((and (eq? (car f) 'define-command) (string? (cadr f))) (list (cadr f)))
        (else '())))

(define (package-api-names text)
  "(package-api-names TEXT) -- the public names a package source TEXT declares: its public!, define-command and defcustom names, sorted"
  (sort (package-update--dedup (apply append (map package-update--form-names (or (scheme-read text) '()))))))

(define (package-api-removed before after)
  "(package-api-removed BEFORE AFTER) -- the names of BEFORE that AFTER has not"
  (filter (lambda (n) (not (member n after))) before))

(define (package-update--connector rest)
  ;; REST after an old name: the text after its arrow, or #f when none
  (let loop ((cs '("->" "=>" "→" "to " "becomes " "is now " "with " "by " "in favour of " "in favor of ")))
    (cond ((null? cs) #f)
          ((string-prefix? (car cs) rest) (substring rest (string-length (car cs)) (string-length rest)))
          (else (loop (cdr cs))))))

(define (package-update--trim-lead s)
  (let loop ((s s))
    (if (and (> (string-length s) 0) (string-search (substring s 0 1) " `'\"("))
        (loop (substring s 1 (string-length s)))
        s)))

(define (package-update--token s)
  (let loop ((i 0))
    (if (and (< i (string-length s)) (package-update--sym-char? (string-ref s i)))
        (loop (+ i 1))
        (substring s 0 i))))

(define (package-update-replacement name notes)
  "(package-update-replacement NAME NOTES) -- what the change NOTES (lines of CHANGES and commit messages) say replaces NAME: (NEW LINE) for 'old -> new', 'renamed old to new' and the like, (#f LINE) when a line names it without a new name, #f when none does"
  (let ((lines (filter (lambda (l) (package-update--has? l name)) notes)))
    (and (pair? lines)
         (let loop ((ls lines))
           (if (null? ls)
               (list #f (string-trim (car lines)))
               (let* ((l (car ls))
                      (at (string-search name l))
                      (rest (package-update--trim-lead (substring l (+ at (string-length name)) (string-length l))))
                      (after (package-update--connector rest))
                      (tok (and after (package-update--token (package-update--trim-lead after)))))
                 (if (and tok (> (string-length tok) 0) (not (equal? tok name)))
                     (list tok (string-trim l))
                     (loop (cdr ls)))))))))

(define (package-fix-plan name from to removed major-from major-to uses)
  "(package-fix-plan NAME FROM TO REMOVED MAJOR-FROM MAJOR-TO USES) -- the notes of a fix-forward todo: what changed, then each use as FILE:LINE, the old name and its replacement; USES are (FILE LINE TEXT OLD REPLACEMENT)"
  (string-append
    name " moved from " (package-update--short from) " to " (package-update--short to)
    (if (> major-to major-from)
        (string-append ", and its :major went from " (number->string major-from) " to " (number->string major-to))
        "")
    ".\n"
    (if (pair? removed) (string-append "Public names it no longer has: " (string-join removed ", ") ".\n") "")
    "\nThe uses in your code:\n"
    (string-join
      (map (lambda (u)
             (let ((file (list-ref u 0)) (line (list-ref u 1)) (text (list-ref u 2))
                   (old (list-ref u 3)) (rep (list-ref u 4)))
               (string-append "- " (abbreviate-file-name file) ":" (number->string line) "  " old " → "
                              (cond ((and rep (car rep)) (string-append (car rep) "  (" (cadr rep) ")"))
                                    (rep (string-append "no new name given; the change says: " (cadr rep)))
                                    (else (string-append "nothing names a replacement; read " name "'s source")))
                              "\n    " text)))
           uses)
      "\n")
    "\n\nRules: fix each use in place, keep the file's style, run the tests beside each package you touch, and load it clean. "
    "Push nothing and open no PR: finish with todo-review so the user reviews the fix."))

(effects! '(read))

(define (package-update--scm-files dir)
  (if (file-directory? dir)
      (map (lambda (f) (string-append dir "/" f))
           (filter (lambda (f) (and (string-suffix? ".scm" f) (not (string-suffix? "-test.scm" f))
                                    (not (equal? f "recipe.scm"))))
                   (list-dir dir)))
      '()))

(define (package-api name)
  "(package-api NAME) -- the public names NAME's checkout declares now, sorted"
  (sort (package-update--dedup
          (apply append (map (lambda (p) (package-api-names (read-file p)))
                             (package-update--scm-files (package-directory (package--name name))))))))

(define (package-held? name)
  "(package-held? NAME) -- #t when packages.lock holds NAME at its commit"
  (let ((e (assoc (package--name name) (package-lock))))
    (and e (> (length e) 3) (plist-get (list-tail e 3) 'held) #t)))

(define (package-previous name)
  "(package-previous NAME) -- the commit NAME was at before its last update, as packages.lock keeps it, or #f"
  (let ((e (assoc (package--name name) (package-lock))))
    (and e (> (length e) 3) (plist-get (list-tail e 3) 'previous))))

(define (package-update--url name)
  (let ((e (assoc name (package-lock))))
    (or (package-recipe-url (package-recipe name)) (and e (cadr e))
        (let ((d (package-directory name)))
          (and (file-exists? (string-append d "/.git")) (package--git d "config --get remote.origin.url"))))))

(define (package-own-source? name)
  "(package-own-source? NAME) -- #t when NAME comes from a source of the user's own, not package-default-org"
  (let* ((url (package-update--url (package--name name)))
         (repo (and (string? url) (package-github-repo url))))
    (not (and repo (equal? (car (string-split repo "/")) package-default-org)))))

(define (package-update-target name)
  "(package-update-target NAME) -- where an update moves NAME: the commit the running release vouches for in priv/standard.lock, 'newest for a package of the user's own source, #f for a develop checkout or a standard package the release does not vouch for"
  (let* ((n (package--name name)) (pin (assoc n (package-core-pins))))
    (cond ((assoc n package-develop-directories) #f)
          (pin (caddr pin))
          ((package-own-source? n) 'newest)
          (else #f))))

(define (package-update--tree dir)
  ;; DIR's .scm files and those of its folders one level down; the clones and dot folders stay out
  (if (not (file-directory? dir))
      '()
      (append (package-update--scm-files dir)
              (apply append
                     (map (lambda (f)
                            (let ((sub (string-append dir "/" (if (string-suffix? "/" f) (substring f 0 (- (string-length f) 1)) f))))
                              (if (and (file-directory? sub) (not (string-prefix? "." f))
                                       (not (equal? sub (package-repos-dir))))
                                  (append (package-update--scm-files sub)
                                          (let ((r (string-append sub "/recipe.scm"))) (if (file-exists? r) (list r) '())))
                                  '())))
                          (list-dir dir))))))

(define (package-user-code-files . except)
  "(package-user-code-files [NAME]) -- the user's own Scheme files: init.scm and custom.scm, the personal package folders, the develop checkouts and the clones of the user's own sources, each with its recipe.scm; NAME's own checkout stays out"
  (let* ((skip (and (pair? except) (package-directory (package--name (car except)))))
         (own (filter (lambda (n) (and (file-exists? (string-append (package-directory n) "/.git"))
                                       (not (assoc n package-develop-directories))
                                       (package-own-source? n)))
                      (package-installed)))
         (dirs (filter (lambda (d) (not (equal? d skip)))
                       (package-update--dedup (append (personal-package-dirs)
                                                      (map cadr package-develop-directories)
                                                      (map package-directory own))))))
    (filter file-exists?
            (package-update--dedup
              (append (map (lambda (f) (string-append (compos-home) "/" f)) '("init.scm" "custom.scm"))
                      (apply append (map package-update--tree dirs)))))))

(define (package-find-uses names . except)
  "(package-find-uses NAMES [PACKAGE]) -- every use of NAMES in the user's own code (package-user-code-files), as ((FILE LINE TEXT NAME) ...)"
  (apply append
         (map (lambda (file)
                (let ((text (read-file file)))
                  (apply append
                         (map (lambda (n)
                                (map (lambda (u) (list file (car u) (cadr u) n))
                                     (package-update-uses-in text n)))
                              names))))
              (apply package-user-code-files except))))

(define (package-find-requires name major)
  "(package-find-requires NAME MAJOR) -- the recipe.scm files of the user's own code that require NAME at a :major other than MAJOR, as ((FILE LINE TEXT WANT) ...)"
  (apply append
         (map (lambda (file)
                (let* ((r (package--read-first file))
                       (reqs (or (and (pair? r) (plist-get (cdr r) ':requires)) '()))
                       (q (find (lambda (q) (and (pair? q) (equal? (package--name (car q)) name)
                                                 (pair? (cdr q)) (number? (cadr q)) (not (= (cadr q) major))))
                                reqs)))
                  (if q
                      (let ((at (package-update-uses-in (read-file file) name)))
                        (list (list file (if (pair? at) (car (car at)) 1) (if (pair? at) (cadr (car at)) "") (cadr q))))
                      '())))
              (filter (lambda (f) (string-suffix? "/recipe.scm" f)) (package-user-code-files name)))))

(effects! '(write))

(define (package-update--plist-set pl k v)
  (let loop ((pl pl) (acc '()))
    (cond ((null? pl) (if v (append (reverse acc) (list k v)) (reverse acc)))
          ((and (pair? (cdr pl)) (eq? (car pl) k)) (loop (cddr pl) acc))
          ((pair? (cdr pl)) (loop (cddr pl) (cons (cadr pl) (cons (car pl) acc))))
          (else (loop '() acc)))))

(define (package-lock-set! name commit . marks)
  "(package-lock-set! NAME COMMIT [KEY VALUE ...]) -- pin NAME at COMMIT in packages.lock (#f keeps the pin) and set its marks, held and previous; a #f value drops a mark. Answers the row"
  (let* ((n (package--name name))
         (rows (package-lock))
         (old (assoc n rows))
         (meta (let loop ((m (if (and old (> (length old) 3)) (list-tail old 3) '())) (ks marks))
                 (if (and (pair? ks) (pair? (cdr ks)))
                     (loop (package-update--plist-set m (car ks) (cadr ks)) (cddr ks))
                     m)))
         (dir (package-directory n))
         (git? (file-exists? (string-append dir "/.git")))
         (row (append (list n (or (and old (cadr old)) (package-update--url n) "")
                            (or commit (and old (caddr old)) (and git? (package--git dir "rev-parse HEAD")) ""))
                      meta)))
    (package-lock-write! (if old
                             (map (lambda (r) (if (equal? (car r) n) row r)) rows)
                             (append rows (list row))))
    row))

(define (package-hold! name . on)
  "(package-hold! NAME [ON]) -- hold NAME at its commit (ON #t), or let it update again (ON #f); no ON flips it. compos-update and U skip a held package. Answers #t when it is held"
  (let* ((n (package--name name))
         (held (if (pair? on) (and (car on) #t) (not (package-held? n)))))
    (package-lock-set! n #f 'held held)
    (message (string-append n (if held " is held at its commit; updates skip it" " updates again")))
    (event-publish! "packages" (if held 'held 'unheld) n)
    held))

(effects! '(write external execute))

(define (package-update--reload! n)
  ;; load the checkout again when it is loaded; #t when it loaded clean
  (let ((main (string-append (package-directory n) "/" n ".scm")))
    (or (not (featurep (string->symbol n)))
        (not (file-exists? main))
        (and (ignore-errors (lambda () (load main) #t)) #t))))

(define (package-update--group)
  (or package-fix-group
      (and (boundp 'group-here) (group-here))
      (let ((g (group-names))) (and (pair? g) (car g)))))

(define (package-fail-forward! name from to removed major-from major-to notes)
  "(package-fail-forward! NAME FROM TO REMOVED MAJOR-FROM MAJOR-TO NOTES) -- find every use of the names REMOVED, and every recipe that requires NAME at another :major, in the user's own code; file a todo with the plan (each use, its file, the old name and its replacement from the change NOTES) and start a chat on it. Answers the todo id, or #f when the user's code uses none"
  (let* ((uses (map (lambda (u) (append u (list (package-update-replacement (list-ref u 3) notes))))
                    (package-find-uses removed name)))
         (reqs (if (> major-to major-from)
                   (map (lambda (r)
                          (list (car r) (cadr r) (caddr r)
                                (string-append "(" name " " (number->string (cadddr r)) ")")
                                (list (string-append "(" name " " (number->string major-to) ")")
                                      (string-append "bring the code to " name "'s :major " (number->string major-to)))))
                        (package-find-requires name major-to))
                   '()))
         (all (append uses reqs)))
    (if (null? all)
        (begin
          (message (string-append name " changed its API"
                                  (if (pair? removed) (string-append " (dropped " (string-join removed ", ") ")") "")
                                  "; your code uses none of it"))
          #f)
        (let* ((group (package-update--group))
               (id (todo-create (string-append "Fix your code for " name "'s API change")
                                (list 'group group 'project package-fix-project
                                      'state (if package-fix-start-chat "todo" "inbox")
                                      'tags '("packages" "fail-forward")
                                      'source (string-append "package-break:" name ":" to)
                                      'goal (string-append "your code uses " name "'s API at " (package-update--short to)
                                                           " and loads clean, reviewed by you")
                                      'notes (package-fix-plan name from to removed major-from major-to all)))))
          (message (string-append name " changed its API: " (number->string (length all))
                                  " uses in your code; todo " id " has the plan"))
          (event-publish! "packages" 'api-break (list name id (length all)))
          (when package-fix-start-chat
            (ignore-errors (lambda () (todo-assign-chat! id group))))
          id))))

(define (package--update-script dir target)
  (let ((g (string-append "git -C " (sh-quote dir) " ")))
    (string-append
      "echo \"@@old $(" g "rev-parse HEAD)\"; "
      "if [ -n \"$(" g "status --porcelain --untracked-files=no)\" ]; then echo @@dirty; else "
      g "fetch --quiet origin 2>/dev/null; "
      (if (eq? target 'newest)
          (string-append "T=$(" g "rev-parse -q --verify '@{u}' || " g "rev-parse -q --verify origin/HEAD); "
                         "if [ -z \"$T\" ]; then echo '@@fail no upstream'; "
                         "elif " g "symbolic-ref -q HEAD >/dev/null; then " g "merge --ff-only --quiet \"$T\" 2>&1 | sed 's/^/@@fail /'; "
                         "else " g "checkout --quiet \"$T\" 2>&1 | sed 's/^/@@fail /'; fi; ")
          (string-append g "checkout --quiet " (sh-quote target) " 2>&1 | sed 's/^/@@fail /'; "))
      "echo \"@@new $(" g "rev-parse HEAD)\"; fi")))

(define (package--update-notes dir from to)
  ;; the change notes between FROM and TO: the CHANGES file, then the commit messages
  (let* ((changes (find file-exists? (map (lambda (f) (string-append dir "/" f)) '("CHANGES.md" "CHANGES" "CHANGELOG.md"))))
         (log (package--git dir (string-append "log --format=%s%n%b " (sh-quote (string-append from ".." to))))))
    (filter (lambda (l) (not (equal? (string-trim l) "")))
            (append (if changes (string-split (read-file changes) "\n") '())
                    (string-split (or log "") "\n")))))

(define (package-update! name . k)
  "(package-update! NAME [K]) -- in a task, move NAME's clone to the commit the release vouches for (package-update-target), keep the commit it left as previous in packages.lock, and load it again when it is loaded. A break never stops it: dropped public names or a raised :major go to package-fail-forward!. K gets (NAME updated FROM TO REMOVED TODO), (NAME current), (NAME held) or (NAME skipped WHY); publishes packages updated"
  (let* ((n (package--name name))
         (done (lambda (r) (when (pair? k) ((car k) r)) r))
         (dir (package-directory n))
         (target (package-update-target n)))
    (cond ((not (file-exists? (string-append dir "/.git"))) (done (list n 'skipped "no clone")))
          ((package-held? n) (done (list n 'held)))
          ((not target)
           (done (list n 'skipped (if (assoc n package-develop-directories)
                                      "a develop checkout"
                                      "the release does not vouch for it"))))
          (else
           (let ((before (package-api n)) (major (package-major n)))
             (shell-command->string
               (package--update-script dir target) (compos-home)
               (lambda (out)
                 (let* ((ls (string-split out "\n"))
                        (val (lambda (tag) (let ((l (find (lambda (l) (string-prefix? tag l)) ls)))
                                             (and l (string-trim (substring l (string-length tag) (string-length l)))))))
                        (from (val "@@old ")) (to (val "@@new ")) (fail (val "@@fail ")))
                   (cond ((find (lambda (l) (equal? (string-trim l) "@@dirty")) ls)
                          (done (list n 'skipped "it has uncommitted changes")))
                         ((or fail (not to) (equal? to ""))
                          (done (list n 'skipped (or fail "git could not move it"))))
                         ((equal? from to) (done (list n 'current)))
                         (else
                          (package-lock-set! n to 'previous from)
                          (let* ((after (package-api n)) (major2 (package-major n))
                                 (removed (package-api-removed before after))
                                 (clean (package-update--reload! n))
                                 (todo (and (or (pair? removed) (> major2 major))
                                            (package-fail-forward! n from to removed major major2
                                                                   (package--update-notes dir from to)))))
                            (unless clean (message (string-append n " updated but did not load clean; see *Messages*")))
                            (event-publish! "packages" 'updated (list n from to))
                            (done (list n 'updated from to removed todo)))))))))))))

(define (package-update-all! . k)
  "(package-update-all! [K]) -- package-update! every installed clone in turn, held ones and develop checkouts skipped; K gets the results; publishes packages updated-all"
  (let ((names (filter (lambda (n) (file-exists? (string-append (package-directory n) "/.git")))
                       (package-installed))))
    (let loop ((ns names) (acc '()))
      (if (null? ns)
          (let* ((rs (reverse acc))
                 (moved (filter (lambda (r) (eq? (cadr r) 'updated)) rs))
                 (fixes (filter (lambda (r) (and (eq? (cadr r) 'updated) (list-ref r 5))) rs)))
            (message (string-append "updated " (number->string (length moved)) " of " (number->string (length rs)) " packages"
                                    (if (pair? fixes)
                                        (string-append "; " (number->string (length fixes)) " API breaks have a fix todo")
                                        "")))
            (event-publish! "packages" 'updated-all (map (lambda (r) (list (car r) (cadr r))) rs))
            (when (pair? k) ((car k) rs))
            rs)
          (package-update! (car ns) (lambda (r) (loop (cdr ns) (cons r acc))))))
    names))

(define (package-rollback! name . k)
  "(package-rollback! NAME [K]) -- put NAME back at the commit its last update left (packages.lock's previous) and hold it there; K gets the commit or #f"
  (let* ((n (package--name name)) (prev (package-previous n)) (dir (package-directory n)))
    (if (not prev)
        (begin (message (string-append n " has no update to roll back")) (when (pair? k) ((car k) #f)) #f)
        (shell-command->string
          (string-append "git -C " (sh-quote dir) " rev-parse HEAD; git -C " (sh-quote dir) " checkout --quiet " (sh-quote prev)
                         " 2>&1 && echo @@ok")
          (compos-home)
          (lambda (out)
            (let ((ok (string-contains? out "@@ok"))
                  (cur (string-trim (car (string-split out "\n")))))
              (if (not ok)
                  (message (string-append "rollback of " n " failed: " (string-trim out)))
                  (begin
                    (package-lock-set! n prev 'previous cur 'held #t)
                    (package-update--reload! n)
                    (message (string-append n " is back at " (package-update--short prev) " and held there; h lets it update again"))
                    (event-publish! "packages" 'rolled-back (list n prev))))
              (when (pair? k) ((car k) (and ok prev)))))))))

(define (package-follow-release! . k)
  "(package-follow-release! [K]) -- when the running release is not the one packages.lock follows, move every pin to it (package-update-all!) and note the release; #f in a checkout or when the lock follows it already"
  (let* ((info (build-info))
         (v (and info (plist-get info 'version)))
         (rel (package-lock-release)))
    (if (or (not (string? v)) (and rel (equal? (cadr rel) v)))
        (begin (when (pair? k) ((car k) #f)) #f)
        (begin
          (message (string-append "compos " v ": moving the packages to the commits it vouches for"))
          (package-update-all!
            (lambda (rs)
              (package-lock-write! (package-lock) (list 'release v))
              (when (pair? k) ((car k) rs))))
          v))))

(define-command "package-update" "Update a package to the commit the release vouches for; an API break files a fix for your code"
  (interactive (lambda (k) (minibuffer-read "Update package: " (package-installed) (lambda (n) (k (list (string-trim n)))))))
  (lambda (n) (package-update! n (lambda (r) (unless (eq? (cadr r) 'updated)
                                                (message (string-append (car r) ": " (symbol->string (cadr r))
                                                                        (if (pair? (cddr r)) (string-append ", " (caddr r)) "")))))))
  'public #t)

(define-command "package-update-all" "Update every package that is not held to the commits the release vouches for"
  (lambda () (message "updating the packages…") (package-update-all!))
  'public #t)

(define-command "package-rollback" "Put a package back at the commit before its last update and hold it there"
  (interactive (lambda (k) (minibuffer-read "Roll back package: " (filter package-previous (package-installed))
                                             (lambda (n) (k (list (string-trim n)))))))
  package-rollback!
  'public #t)

(define-command "package-hold" "Hold a package at its commit, or let a held one update again"
  (interactive (lambda (k) (minibuffer-read "Hold package: " (package-installed) (lambda (n) (k (list (string-trim n)))))))
  package-hold!
  'public #t)

(effects! '(pure))
(public! 'package-api-names "(package-api-names TEXT) -- the public names a package source TEXT declares: its public!, define-command and defcustom names, sorted")
(public! 'package-api-removed "(package-api-removed BEFORE AFTER) -- the names of BEFORE that AFTER has not")
(public! 'package-update-uses-in "(package-update-uses-in TEXT NAME) -- where NAME stands as a whole symbol in TEXT, as ((LINE TEXT) ...)")
(public! 'package-update-replacement "(package-update-replacement NAME NOTES) -- what the change NOTES say replaces NAME: (NEW LINE), (#f LINE) when a line names it without a new name, or #f")
(public! 'package-fix-plan "(package-fix-plan NAME FROM TO REMOVED MAJOR-FROM MAJOR-TO USES) -- the notes of a fix-forward todo; USES are (FILE LINE TEXT OLD REPLACEMENT)")
(effects! '(read))
(public! 'package-api "(package-api NAME) -- the public names NAME's checkout declares now, sorted")
(public! 'package-held? "(package-held? NAME) -- #t when packages.lock holds NAME at its commit")
(public! 'package-previous "(package-previous NAME) -- the commit NAME was at before its last update, or #f")
(public! 'package-own-source? "(package-own-source? NAME) -- #t when NAME comes from a source of the user's own, not package-default-org")
(public! 'package-update-target "(package-update-target NAME) -- where an update moves NAME: the release's commit, 'newest for the user's own source, or #f")
(public! 'package-user-code-files "(package-user-code-files [NAME]) -- the user's own Scheme files: init.scm, custom.scm, personal packages, develop checkouts and own-source clones; NAME's checkout stays out")
(public! 'package-find-uses "(package-find-uses NAMES [PACKAGE]) -- every use of NAMES in the user's own code as ((FILE LINE TEXT NAME) ...)")
(public! 'package-find-requires "(package-find-requires NAME MAJOR) -- the user's recipe.scm files that require NAME at another :major, as ((FILE LINE TEXT WANT) ...)")
(effects! '(write))
(public! 'package-lock-set! "(package-lock-set! NAME COMMIT [KEY VALUE ...]) -- pin NAME at COMMIT (#f keeps it) and set its marks held and previous; answers the row")
(public! 'package-hold! "(package-hold! NAME [ON]) -- hold NAME at its commit, or let it update again; no ON flips it; #t when held")
(effects! '(write external execute))
(public! 'package-update! "(package-update! NAME [K]) -- in a task, move NAME to the commit the release vouches for and reload it; dropped names or a raised :major file a fix todo for the user's code (package-fail-forward!); K gets (NAME updated FROM TO REMOVED TODO) or (NAME current|held|skipped ...)")
(public! 'package-update-all! "(package-update-all! [K]) -- package-update! every clone that is not held, in turn; K gets the results")
(public! 'package-rollback! "(package-rollback! NAME [K]) -- put NAME back at its previous commit and hold it; K gets the commit or #f")
(public! 'package-fail-forward! "(package-fail-forward! NAME FROM TO REMOVED MAJOR-FROM MAJOR-TO NOTES) -- file a todo with the plan to fix every use of the dropped names in the user's code and start a chat on it; the todo id, or #f when nothing uses them")
(public! 'package-follow-release! "(package-follow-release! [K]) -- when the running release is not the one packages.lock follows, update every package to it and note the release")

;; the first boot of a new release moves the pins to it; the git work runs in a task
(effects! '(write external execute))
(when (build-info) (package-follow-release!))

(provide 'package-update)
