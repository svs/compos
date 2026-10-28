;;; todo.scm --- the shared todo list every app and agent coordinates through.
;;;
;;; A task is a level-2 morg heading in a project's todos.md, found by
;;; todo-directories: hiring/todos.md holds the tasks of project "hiring".
;;; The heading keyword stays TODO or DONE, so morg-todo and the agenda
;;; read these files unchanged; the finer state is #+state.
;;;
;;;   ## TODO Nudge Anusha on the offer :opptra:client:
;;;   DEADLINE: <2026-09-26>
;;;   #+id: t-260924-154612-073
;;;   #+state: todo
;;;   #+assignee: agent:closer
;;;   #+priority: A
;;;   #+source: gmail:18c2f0a
;;;   #+created: 2026-09-24 15:46
;;;   #+by: agent:mail-trawler
;;;
;;;   Free notes.
;;;
;;;   #+log: 2026-09-24 15:46 agent:mail-trawler created
;;;
;;; States: inbox (found, not yet triaged by a human) · todo (triaged,
;;; free to take) · doing (claimed) · waiting (blocked on someone) ·
;;; review (needs a human OK, e.g. before anything goes out) · done ·
;;; cancelled.
;;;
;;; Every writer goes through todo-create and todo-update, so each change
;;; lands in the task's log under the name of whoever made it. An open
;;; file buffer is edited live, and saved only when it held no unsaved
;;; work of its own. A task without #+id is the writer's own note, and the
;;; API leaves it alone.
;;;
;;; OFFSET RULE: byte offsets only (string-byte-length, substring-bytes).

(domain! 'writing)
(effects! '(read))

(defcustom 'todo-directories '("~/.compos/**/todos.md")
  "Where the todo files live: paths and patterns, where `*` matches within one name and `**` any depth of folders. A todos.md is the project its folder names; any other file, the project its own name gives. A new project goes where the first pattern puts it.")

(defcustom 'todo-user "svs"
  "The name a change is logged under when the caller names nobody.")

(defcustom 'todo-default-project "general"
  "The project of a task created without one.")

(define *todo-states* '("inbox" "todo" "doing" "waiting" "review" "done" "cancelled"))
(define *todo-closed* '("done" "cancelled"))
;; the #+ lines, in the order they are written
(define *todo-fields* '(id state assignee chats priority urgent source parent depends created by group))
;; what todo-update may change
(define *todo-settable*
  '(title state project assignee chats priority urgent deadline scheduled tags source parent depends notes group))

;;; --- small helpers -----------------------------------------------------------

(define (todo--join dir n) (if (string-suffix? "/" dir) (string-append dir n) (string-append dir "/" n)))
(define (todo--now) (format-time (current-time) "%Y-%m-%d %H:%M"))
(define (todo--today) (format-time (current-time) "%Y-%m-%d"))

(define (todo--sub s g i) (substring-bytes s (car (nth i g)) (cadr (nth i g))))
(define (todo--blank? s) (or (not s) (and (string? s) (equal? (string-trim s) ""))))
(define (todo--first pred xs) (let ((hit (filter pred xs))) (and (pair? hit) (car hit))))
(define (todo--words s)
  (filter (lambda (w) (not (equal? w ""))) (string-split (string-trim s) " ")))

(define (todo--fail &rest parts) (error (apply string-append (cons "todo: " parts))))

(define (todo-date s)
  "(todo-date S) — today, tomorrow, +3d, 2w or YYYY-MM-DD as YYYY-MM-DD; blank is #f"
  (let ((day (lambda (n) (format-time (time+ (current-time) n) "%Y-%m-%d"))))
    (cond ((todo--blank? s) #f)
          ((re-match "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" s) s)
          ((equal? s "today") (day 0))
          ((equal? s "tomorrow") (day 1))
          (else
           (let ((g (re-groups "^[+]?([0-9]+)([dw])$" s 0)))
             (if g
                 (let ((n (string->number (todo--sub s g 1))))
                   (day (if (equal? (todo--sub s g 2) "w") (* 7 n) n)))
                 (todo--fail "not a date: " s)))))))

(define (todo--date-num d) (if d (string->number (string-join (string-split d "-") "")) 99999999))

(define (todo--slug s)
  (let ((w (todo--words (string-downcase s))))
    (if (null? w) (todo--fail "empty project name") (string-join w "-"))))

(define (todo--tags v)
  (cond ((not v) '())
        ((pair? v) v)
        ((null? v) '())
        (else (filter (lambda (x) (not (equal? x "")))
                      (string-split (string-join (string-split v " ") ":") ":")))))

(define (todo--ids v)
  (cond ((pair? v) v)
        ((or (null? v) (todo--blank? v)) '())
        (else (todo--words v))))

(define (todo--priority p)
  (cond ((todo--blank? p) #f)
        ((member (string-upcase p) '("A" "B" "C")) (string-upcase p))
        (else (todo--fail "priority is A, B or C, not " p))))

(define (todo--state s)
  (if (member s *todo-states*) s
      (todo--fail "state is one of " (string-join *todo-states* ", ") ", not " (if (string? s) s "?"))))

(define (todo--new-id)
  (string-append "t-" (format-time (current-time) "%y%m%d-%H%M%S")
                 "-" (number->string (+ 100 (random 900)))))

;; A log entry is one line of the file: a line break in TEXT would end the
;; entry and put the rest in the task's body.
(define (todo--log-line who text)
  (string-append (todo--now) " " who " " (re-replace-all "\\s*\\n\\s*" (string-trim text) " ")))

;;; --- files -------------------------------------------------------------------

;; the files todo-directories names. Expanding `**` walks every folder
;; under it, which is slow on a big tree, so the list is kept and a task
;; renews it: at load, on `g`, and when a new project's file is written.
(define (todo--glob pattern)
  (let walk ((dir "/") (segs (cdr (string-split (expand-path pattern) "/"))))
    (let ((names (lambda () (let ((l (and (file-directory? dir) (list-dir dir)))) (if (pair? l) l '()))))
          (subdirs (lambda (ns) (map (lambda (n) (substring-bytes n 0 (- (string-byte-length n) 1)))
                                     (filter (lambda (n) (and (string-suffix? "/" n) (not (string-prefix? "." n)))) ns)))))
      (cond ((null? segs) (if (and (file-exists? dir) (not (file-directory? dir))) (list dir) '()))
            ((equal? (car segs) "**")
             (fold (lambda (acc d) (append acc (walk (todo--join dir d) segs)))
                   (walk dir (cdr segs)) (subdirs (names))))
            ((string-contains? (car segs) "*")
             (let ((re (string-append "^" (string-join (map regexp-quote (string-split (car segs) "*")) "[^/]*") "$")))
               (fold (lambda (acc n) (append acc (walk (todo--join dir n) (cdr segs))))
                     '()
                     (filter (lambda (n) (and (not (string-prefix? "." n)) (re-match re n)))
                             (map (lambda (n) (if (string-suffix? "/" n) (substring-bytes n 0 (- (string-byte-length n) 1)) n)) (names))))))
            (else (walk (todo--join dir (car segs)) (cdr segs)))))))

;; A worktree daemon keeps its own copy of ~/.compos under worktree-daemons/;
;; its todos.md files are stale copies of the user's, so `**` must not reach them.
(define (todo--resolve)
  (fold (lambda (acc f) (if (or (member f acc) (string-contains? f "/worktree-daemons/")) acc (append acc (list f))))
        '() (fold (lambda (acc p) (append acc (todo--glob p))) '() todo-directories)))

(define *todo-files* #f)

(define (todo--files)
  (unless *todo-files* (set! *todo-files* (todo--resolve)))
  (filter file-exists? *todo-files*))

(define (todo--rescan!)
  (task-run! todo--resolve
    (lambda (ok? files)
      (when ok?
        (set! *todo-files* files)
        (todo--agenda-sync!)
        (todo--refresh-all!)))))

;; a project's file: the one it has, else where the first pattern puts it,
;; the first wildcard standing for the project and a later ** for nothing
(define (todo--project-file project)
  (or (todo--first (lambda (f) (equal? (todo--file-project f) project)) (todo--files))
      (let loop ((segs (string-split (expand-path (car todo-directories)) "/")) (done #f) (acc '()))
        (cond ((null? segs) (string-join (reverse acc) "/"))
              ((and done (equal? (car segs) "**")) (loop (cdr segs) done acc))
              ((string-contains? (car segs) "*")
               (loop (cdr segs) #t
                     (cons (string-join (string-split (if (equal? (car segs) "**") "*" (car segs)) "*") (todo--slug project)) acc)))
              (else (loop (cdr segs) done (cons (car segs) acc)))))))

(define (todo--file-project path)
  (let* ((parts (string-split path "/"))
         (n (list-ref parts (- (length parts) 1))))
    (if (and (equal? n "todos.md") (> (length parts) 1))
        (list-ref parts (- (length parts) 2))
        (if (string-suffix? ".md" n) (substring-bytes n 0 (- (string-byte-length n) 3)) n))))

;; an open buffer may hold unsaved edits, so it reads live
(define (todo--text path)
  (if (buffer-exists? path)
      (buffer-text path)
      (let ((t (read-file path))) (if (string? t) t ""))))

;;; --- parse -------------------------------------------------------------------

;; "## TODO title :a:b:" -> (KW TITLE TAGS), else #f
(define (todo--heading line)
  (let ((g (re-groups "^##[ \t]+(TODO|DONE)[ \t]+(.*)$" line 0)))
    (and g
         (let* ((rest (todo--sub line g 2))
                (tg (re-groups "[ \t](:[A-Za-z0-9_@:-]+:)[ \t]*$" rest 0)))
           (list (todo--sub line g 1)
                 (string-trim (if tg (substring-bytes rest 0 (car (car tg))) rest))
                 (if tg (todo--tags (todo--sub rest tg 1)) '()))))))

;; a line that ends the task above it
(define (todo--boundary? line) (re-match "^[#][#]?[ \t]" line))

(define (todo--trim-head ls)
  (if (and (pair? ls) (todo--blank? (car ls))) (todo--trim-head (cdr ls)) ls))
(define (todo--trim-tail ls) (reverse (todo--trim-head (reverse ls))))

(define (todo--set-prop t k v)
  (cond ((equal? k "log") (plist-put t 'log (cons v (plist-get t 'log))))
        ((equal? k "depends") (plist-put t 'depends (todo--ids v)))
        ((equal? k "chats") (plist-put t 'chats (todo--ids v)))
        ((member (string->symbol k) *todo-fields*)
         (plist-put t (string->symbol k) (if (equal? v "") #f v)))
        (else (plist-put t 'extra (cons (list k v) (plist-get t 'extra))))))

;; CUR is (FROM POS HEADING BODY-LINES); FROM counts lines from 0
(define (todo--task path cur)
  (let* ((head (caddr cur))
         (body (todo--trim-tail (nth 3 cur)))
         (base (list 'id #f 'kw (car head) 'title (cadr head) 'tags (caddr head)
                     'project (todo--file-project path) 'file path
                     'from (car cur) 'to (+ (car cur) 1 (length body)) 'pos (cadr cur)
                     'deadline #f 'scheduled #f 'depends '() 'log '() 'extra '())))
    (let loop ((ls body) (t base) (notes '()))
      (if (null? ls)
          (let* ((t (plist-put t 'notes (string-join (todo--trim-tail (todo--trim-head (reverse notes))) "\n")))
                 (t (plist-put t 'log (reverse (plist-get t 'log))))
                 (t (plist-put t 'extra (reverse (plist-get t 'extra)))))
            (if (plist-get t 'state) t
                (plist-put t 'state (if (equal? (car head) "DONE") "done" "inbox"))))
          (let* ((line (car ls))
                 (p (re-groups "^#[+]([A-Za-z0-9_-]+):[ \t]*(.*)$" line 0)))
            (cond
              ((re-match "^[ \t]*(SCHEDULED|DEADLINE):" line)
               (let* ((d (re-groups "DEADLINE:[ \t]*<([0-9-]+)" line 0))
                      (s (re-groups "SCHEDULED:[ \t]*<([0-9-]+)" line 0))
                      (t (if d (plist-put t 'deadline (todo--sub line d 1)) t))
                      (t (if s (plist-put t 'scheduled (todo--sub line s 1)) t)))
                 (loop (cdr ls) t notes)))
              (p (loop (cdr ls)
                       (todo--set-prop t (string-downcase (todo--sub line p 1))
                                       (string-trim (todo--sub line p 2)))
                       notes))
              (else (loop (cdr ls) t (cons line notes)))))))))

;; every task in TEXT, in file order. The markdown grammar gives each
;; level-2 section and its span, fenced code and all; without the grammar
;; a fence-aware line walk does the same.
(define todo--ts-sections "(section (atx_heading (atx_h2_marker))) @task")

(define (todo--parse path text)
  (if (not (member "markdown" (ts-installed-grammars)))
      (todo--parse-lines path text)
      (let loop ((caps (filter (lambda (c) (equal? (car c) "task"))
                               (ts-query-string "markdown" text todo--ts-sections)))
                 (line 0) (at 0) (acc '()))
        (if (null? caps)
            (filter (lambda (t) (plist-get t 'id)) (reverse acc))
            (let* ((s (cadr (car caps)))
                   (line (+ line (- (length (string-split (substring-bytes text at s) "\n")) 1)))
                   (ls (split-lines (substring-bytes text s (caddr (car caps)))))
                   (head (and (pair? ls) (todo--heading (car ls)))))
              (loop (cdr caps) line s
                    (if head (cons (todo--task path (list line s head (cdr ls))) acc) acc)))))))

(define (todo--parse-lines path text)
  (let loop ((ls (split-lines text)) (i 0) (pos 0) (fence #f) (cur #f) (acc '()))
    (let ((close (lambda () (if cur (cons (todo--task path cur) acc) acc)))
          (add (lambda (line) (and cur (list (car cur) (cadr cur) (caddr cur)
                                             (append (nth 3 cur) (list line)))))))
      (if (null? ls)
          (filter (lambda (t) (plist-get t 'id)) (reverse (close)))
          (let* ((line (car ls))
                 (next (+ pos (string-byte-length line) 1))
                 (step (lambda (fence cur acc) (loop (cdr ls) (+ i 1) next fence cur acc))))
            (cond
              ((and fence (morg-fence-close? line)) (step #f (add line) acc))
              (fence (step #t (add line) acc))
              ((morg-fence-info line) (step #t (add line) acc))
              ((todo--heading line) (step #f (list i pos (todo--heading line) '()) (close)))
              ((todo--boundary? line) (step #f #f (close)))
              (else (step #f (add line) acc))))))))


;; parsing is the slow part of a read, so each file's tasks are kept with
;; the text they came from and parsed again only when that text changes
(define *todo-parse-cache* '())

(define (todo--parsed f)
  (let ((text (todo--text f))
        (hit (assoc f *todo-parse-cache*)))
    (if (and hit (equal? (cadr hit) text))
        (caddr hit)
        (let ((tasks (todo--parse f text)))
          (set! *todo-parse-cache*
                (cons (list f text tasks)
                      (remove (lambda (e) (equal? (car e) f)) *todo-parse-cache*)))
          tasks))))

(define (todo--all)
  (fold (lambda (acc f) (append acc (todo--parsed f))) '() (todo--files)))

;;; --- render ------------------------------------------------------------------

(define (todo--render t)
  (let* ((tags (plist-get t 'tags))
         (notes (plist-get t 'notes))
         (logs (plist-get t 'log))
         (field (lambda (k)
                  (let ((v (plist-get t k)))
                    (cond ((null? v) '())
                          ((pair? v) (list (string-append "#+" (symbol->string k) ": " (string-join v " "))))
                          ((todo--blank? v) '())
                          (else (list (string-append "#+" (symbol->string k) ": " v))))))))
    (string-join
      (append
        (list (string-append "## " (if (member (plist-get t 'state) *todo-closed*) "DONE" "TODO")
                             " " (plist-get t 'title)
                             (if (pair? tags) (string-append " :" (string-join tags ":") ":") "")))
        (if (plist-get t 'deadline) (list (string-append "DEADLINE: <" (plist-get t 'deadline) ">")) '())
        (if (plist-get t 'scheduled) (list (string-append "SCHEDULED: <" (plist-get t 'scheduled) ">")) '())
        (fold (lambda (acc k) (append acc (field k))) '() *todo-fields*)
        (map (lambda (kv) (string-append "#+" (car kv) ": " (cadr kv))) (or (plist-get t 'extra) '()))
        (if (todo--blank? notes) '() (list "" notes))
        (if (pair? logs) (cons "" (map (lambda (l) (string-append "#+log: " l)) logs)) '()))
      "\n")))

;;; --- write -------------------------------------------------------------------

(effects! '(write))

(define (todo--save! path) (with-current-buffer path (lambda () (buffer-save!))))

;; replace task T's lines with NEW, or delete them (and one blank after)
;; when NEW is #f
(define (todo--write-span! t new)
  (let* ((path (plist-get t 'file))
         (ls (split-lines (todo--text path)))
         (from (plist-get t 'from))
         (to0 (plist-get t 'to))
         (to (if (and (not new) (< to0 (length ls)) (todo--blank? (nth to0 ls))) (+ to0 1) to0)))
    (if (buffer-exists? path)
        (let* ((old (string-join (list-head (list-tail ls from) (- to from)) "\n"))
               (dirty (buffer-modified? path))
               (r (if new
                      (buffer-replace! path old new)
                      (buffer-replace! path (string-append old "\n") ""))))
          (unless (equal? r "edited") (todo--fail r))
          (unless dirty (todo--save! path)))
        (write-file! path (string-join (append (list-head ls from)
                                               (if new (list new) '())
                                               (list-tail ls to))
                                       "\n")))))

(define (todo--append! path text)
  (let ((sep (lambda (cur) (cond ((equal? cur "") "")
                                 ((string-suffix? "\n" cur) "\n")
                                 (else "\n\n")))))
    (cond ((buffer-exists? path)
           (let ((dirty (buffer-modified? path)))
             (buffer-append! path (string-append (sep (buffer-text path)) text "\n"))
             (unless dirty (todo--save! path))))
          ((file-exists? path)
           (let ((cur (todo--text path)))
             (write-file! path (string-append cur (sep cur) text "\n"))))
          (else
           (write-file! path (string-append "# " (todo--file-project path) "\n\n" text "\n"))
           (set! *todo-files* (append (todo--files) (list path)))
           (todo--agenda-sync!)))))

;; the agenda reads every project's todos.md; a new project joins it here
(define (todo--agenda-sync!)
  (let* ((mine (map abbreviate-file-name (todo--files)))
         (others (filter (lambda (f) (let ((p (expand-path f)))
                                       (not (or (member p (todo--files))
                                                (and (string-suffix? "todos.md" p) (not (file-exists? p)))))))
                         morg-agenda-files))
         (want (append others mine)))
    (unless (equal? want morg-agenda-files)
      (customize-save! 'morg-agenda-files want))
    want))

;;; --- the API: reading ------------------------------------------------------

(effects! '(read))

(define (todo-get id)
  "(todo-get ID) — the task as a plist, or #f"
  (todo--first (lambda (t) (equal? (plist-get t 'id) id)) (todo--all)))

(define (todo--must id) (or (todo-get id) (todo--fail "no task " (if (string? id) id "?"))))

(define (todo--overdue? t)
  (and (not (member (plist-get t 'state) *todo-closed*))
       (plist-get t 'deadline)
       (< (todo--date-num (plist-get t 'deadline)) (todo--date-num (todo--today)))))

;; every dependency is closed
(define (todo--ready? t all)
  (fold (lambda (ok dep)
          (and ok (let ((d (todo--first (lambda (x) (equal? (plist-get x 'id) dep)) all)))
                    (or (not d) (and (member (plist-get d 'state) *todo-closed*) #t)))))
        #t (plist-get t 'depends)))

(define (todo--match? t spec all)
  (let ((get (lambda (k) (plist-get spec k)))
        (state (plist-get t 'state)))
    (and (cond ((get 'state) (member state (if (pair? (get 'state)) (get 'state) (list (get 'state)))))
               ((get 'all) #t)
               (else (not (member state *todo-closed*))))
         (or (not (get 'project)) (equal? (plist-get t 'project) (todo--slug (get 'project))))
         (or (not (get 'assignee))
             (if (equal? (get 'assignee) "none")
                 (not (plist-get t 'assignee))
                 (equal? (plist-get t 'assignee) (get 'assignee))))
         (or (not (get 'tag)) (member (get 'tag) (plist-get t 'tags)))
         (or (not (get 'text))
             (string-contains? (string-downcase (string-append (plist-get t 'title) " " (plist-get t 'notes)))
                               (string-downcase (get 'text))))
         (or (not (get 'due-before))
             (and (plist-get t 'deadline)
                  (<= (todo--date-num (plist-get t 'deadline)) (todo--date-num (todo-date (get 'due-before))))))
         (or (not (get 'overdue)) (todo--overdue? t))
         (or (not (get 'ready)) (and (equal? state "todo") (todo--ready? t all)))
         (or (not (get 'parent)) (equal? (plist-get t 'parent) (get 'parent)))
         (or (not (get 'source))
             (and (plist-get t 'source) (string-prefix? (get 'source) (plist-get t 'source))))
         #t)))

(define (todo--rank x xs)
  (let loop ((xs xs) (i 0))
    (cond ((null? xs) i) ((equal? (car xs) x) i) (else (loop (cdr xs) (+ i 1))))))

;; review first (it waits on a human), then doing, todo, inbox, waiting;
;; within a state by priority, deadline, age
(define (todo--sort ts)
  (map cadr
       (sort (map (lambda (t)
                    (list (list (todo--rank (plist-get t 'state) '("review" "doing" "todo" "inbox" "waiting" "done" "cancelled"))
                                (todo--rank (or (plist-get t 'priority) "B") '("A" "B" "C"))
                                (todo--date-num (plist-get t 'deadline))
                                (or (plist-get t 'created) ""))
                          t))
                  ts))))

(define (todo-list &optional spec)
  "(todo-list [SPEC]) — tasks, most urgent first. SPEC keys: state (one or a list), all, project, assignee (none = unassigned), tag, text, due-before, overdue, ready, parent, source (a prefix). Without state or all, only open tasks."
  (let ((all (todo--all)) (spec (or spec '())))
    (todo--sort (filter (lambda (t) (todo--match? t spec all)) all))))

(define (todo-next who &optional spec)
  "(todo-next WHO [SPEC]) — the most urgent ready task for WHO: assigned to WHO first, else unassigned; #f when none"
  (let* ((spec (or spec '()))
         (mine (todo-list (append spec (list 'ready #t 'assignee who))))
         (free (todo-list (append spec (list 'ready #t 'assignee "none")))))
    (cond ((pair? mine) (car mine)) ((pair? free) (car free)) (else #f))))

(define (todo-projects)
  "(todo-projects) — every project name"
  (map todo--file-project (todo--files)))

(category! 'writing)
(public! 'todo-get "(todo-get ID) — one task as a plist, or #f")
(public! 'todo-list "(todo-list [SPEC]) — tasks, most urgent first; SPEC keys: state, all, project, assignee (none = unassigned), tag, text, due-before, overdue, ready, parent, source")
(public! 'todo-next "(todo-next WHO [SPEC]) — the most urgent ready task for WHO, else an unassigned one; #f when none")
(public! 'todo-projects "(todo-projects) — every project name")

;;; --- the API: writing --------------------------------------------------------
;;; PROPS is a plist. Every writer may pass 'by, the name the change is
;;; logged under; an agent passes its own, e.g. agent:mail-trawler.

(effects! '(write))

;; the group that files a task: the agent's chat, else the buffer it runs in,
;; else the group in front. Assigning starts the chat there, so the task gets
;; that group's config.
(define (todo--origin-group who)
  (let* ((slug (and (string? who) (string-prefix? "agent:" who) (substring who 6 (string-length who))))
         (info (and slug (agent-info slug)))
         (chat (and info (plist-get info 'buffer))))
    (or (and chat (group-resolve-id (buffer-group chat)))
        (group-resolve-id (buffer-group (current-buffer)))
        (group-here))))

;; the group to assign a task in: the one that filed it, while it lives
(define (todo--home-group t)
  (group-resolve-id (plist-get t 'group)))

(define (todo--group-names)
  (string-join (filter (lambda (n) (and (string? n) (not (string-prefix? "*" n)))) (map car (group-name-table))) ", "))

(define (todo--group-of g)
  (cond ((todo--blank? g)
         (todo--fail "a task needs 'group, the group it belongs to. \"Put a todo in X\" means group X: pass (list 'group \"X\" ...), a group name or id. Groups: " (todo--group-names)))
        ((group-resolve-id g))
        (else (todo--fail "no group " (if (string? g) g "?") ". Pass a group name or id from: " (todo--group-names)))))

(define (todo-create title &optional props)
  "(todo-create TITLE PROPS) — file a task; return its id. PROPS must hold group, a group name or id: the task shows in that group's todo list, and assigning starts the chat there. Without it, or with an unknown one, it errors with the groups to pick from. PROPS may also hold project, state (default inbox), assignee, priority, deadline, scheduled, tags, source, parent, depends, notes, by. A source already filed is not filed twice: that task's id comes back."
  (let* ((props (or props '()))
         (src (plist-get props 'source))
         (dup (and (not (todo--blank? src))
                   (todo--first (lambda (t) (equal? (plist-get t 'source) src)) (todo--all)))))
    (if dup
        (plist-get dup 'id)
        (let* ((who (or (plist-get props 'by) todo-user))
               (group (todo--group-of (plist-get props 'group)))
               (id (todo--new-id))
               (t (list 'id id
                        'title (string-join (todo--words (string-join (split-lines title) " ")) " ")
                        'state (todo--state (or (plist-get props 'state) "inbox"))
                        'tags (todo--tags (plist-get props 'tags))
                        'assignee (if (todo--blank? (plist-get props 'assignee)) #f (plist-get props 'assignee))
                        'priority (todo--priority (plist-get props 'priority))
                        'deadline (todo-date (plist-get props 'deadline))
                        'scheduled (todo-date (plist-get props 'scheduled))
                        'source (if (todo--blank? src) #f src)
                        'parent (plist-get props 'parent)
                        'depends (todo--ids (plist-get props 'depends))
                        'created (todo--now)
                        'by who
                        'group group
                        'notes (or (plist-get props 'notes) "")
                        'extra '()
                        'log (list (todo--log-line who "created")))))
          (when (todo--blank? (plist-get t 'title)) (todo--fail "a task needs a title"))
          (todo--append! (todo--project-file (or (plist-get props 'project) todo-default-project))
                         (todo--render t))
          id))))

(define (todo--norm k v)
  (cond ((equal? k 'state) (todo--state v))
        ((equal? k 'project) (todo--slug v))
        ((member k '(deadline scheduled)) (todo-date v))
        ((equal? k 'tags) (todo--tags v))
        ((member k '(depends chats)) (todo--ids v))
        ((equal? k 'priority) (todo--priority v))
        ;; time-sensitive or not: "yes" or nothing
        ((equal? k 'urgent) (if (or (equal? v #t) (and (string? v) (member (string-downcase (string-trim v)) '("yes" "y" "t" "true")))) "yes" #f))
        ((equal? k 'notes) (or v ""))
        ((equal? k 'title) (if (todo--blank? v) (todo--fail "a task needs a title") (string-trim v)))
        ((todo--blank? v) #f)
        (else v)))

(define (todo--show v)
  (cond ((not v) "-") ((null? v) "-") ((pair? v) (string-join v " ")) (else v)))

(define (todo--change k old new)
  (cond ((equal? k 'notes) "notes edited")
        ((equal? k 'state) (string-append "state " (todo--show old) " -> " (todo--show new)))
        (else (string-append (symbol->string k) " " (todo--show new)))))

(define (todo--split-log props)
  ;; a log entry is one line: a longer text leaves its first line in the
  ;; log and goes whole to the notes, where its line breaks stay
  (let ((text (plist-get props 'log)))
    (if (and (string? text) (string-contains? (string-trim text) "\n"))
        (append (plist-put props 'log (string-append (first-line text) "  (more in notes)"))
                (list 'note (string-trim text)))
        props)))

(define (todo-update id props)
  "(todo-update ID PROPS) — change a task; return it. PROPS: any of title, state, project, assignee, chats, priority, urgent (#t or #f), deadline, scheduled, tags, source, parent, depends, notes (#f or blank clears one), plus note (text added to the notes), log (a line for the log) and by (who). Each change is logged."
  (let* ((t (todo--must id))
         (who (or (plist-get props 'by) todo-user))
         (props (todo--split-log props)))
    (let loop ((ps props) (new t) (changes '()))
      (if (pair? ps)
          (let ((k (car ps)) (v (cadr ps)))
            (cond
              ((member k '(by log)) (loop (cddr ps) new changes))
              ((equal? k 'note)
               (if (todo--blank? v)
                   (loop (cddr ps) new changes)
                   (loop (cddr ps)
                         (plist-put new 'notes (if (todo--blank? (plist-get new 'notes)) v
                                                   (string-append (plist-get new 'notes) "\n\n" v)))
                         (cons "note added" changes))))
              ((not (member k *todo-settable*))
               (todo--fail "cannot set " (symbol->string k)))
              (else
               (let ((v (todo--norm k v)))
                 (if (equal? v (todo--norm k (plist-get new k)))
                     (loop (cddr ps) new changes)
                     (loop (cddr ps) (plist-put new k v) (cons (todo--change k (plist-get new k) v) changes)))))))
          (let* ((text (plist-get props 'log))
                 (lines (map (lambda (c) (todo--log-line who c))
                             (append (reverse changes) (if (todo--blank? text) '() (list text))))))
            (if (null? lines)
                t
                (let ((new (plist-put new 'log (append (plist-get new 'log) lines))))
                  (if (equal? (plist-get new 'project) (plist-get t 'project))
                      (todo--write-span! t (todo--render new))
                      (begin (todo--write-span! t #f)
                             (todo--append! (todo--project-file (plist-get new 'project)) (todo--render new))))
                  (todo-get id))))))))

(define (todo-log id text &optional who)
  "(todo-log ID TEXT [WHO]) — add a line to the task's log"
  (todo-update id (list 'log text 'by (or who todo-user))))

(define (todo-triage id &optional props)
  "(todo-triage ID [PROPS]) — accept an inbox task: state todo, plus any PROPS"
  (todo-update id (append (or props '()) (list 'state "todo"))))

(define (todo-claim id who)
  "(todo-claim ID WHO) — take a ready todo task for WHO: state doing. Return the task, or #f when it is not free: taken, not triaged, or waiting on a dependency."
  (let ((t (todo--must id)))
    (cond ((and (equal? (plist-get t 'state) "doing") (equal? (plist-get t 'assignee) who)) t)
          ((not (equal? (plist-get t 'state) "todo")) #f)
          ((and (plist-get t 'assignee) (not (equal? (plist-get t 'assignee) who))) #f)
          ((not (todo--ready? t (todo--all))) #f)
          (else (todo-update id (list 'state "doing" 'assignee who 'by who))))))

(define (todo-done id &optional result who)
  "(todo-done ID [RESULT] [WHO]) — close the task as done; RESULT goes to the log"
  (todo-update id (list 'state "done" 'log result 'by (or who todo-user))))

(define (todo-cancel id &optional reason who)
  "(todo-cancel ID [REASON] [WHO]) — close the task as cancelled"
  (todo-update id (list 'state "cancelled" 'log reason 'by (or who todo-user))))

(define (todo-wait id reason &optional who)
  "(todo-wait ID REASON [WHO]) — park the task: waiting on someone or something"
  (todo-update id (list 'state "waiting" 'log reason 'by (or who todo-user))))

(define (todo-review id summary &optional who)
  "(todo-review ID SUMMARY [WHO]) — hand the task to a human to approve, e.g. a draft before it is sent"
  (todo-update id (list 'state "review" 'log summary 'by (or who todo-user))))

(define (todo-approve id &optional text who)
  "(todo-approve ID [TEXT] [WHO]) — approve a task in review: back to todo for its assignee, logged as approved"
  (todo-update id (list 'state "todo"
                        'log (if (todo--blank? text) "approved" (string-append "approved: " text))
                        'by (or who todo-user))))

;;; --- the list ----------------------------------------------------------------

(category! 'writing)
(public! 'todo-create "(todo-create TITLE PROPS) — file a task; answers its id. PROPS must hold 'group, a group name or id (\"put a todo in X\" is group X); 'by is the name the change is logged under")
(public! 'todo-update "(todo-update ID PROPS) — change the task's fields; each change lands in its log")
(public! 'todo-log "(todo-log ID TEXT [WHO]) — add a line to the task's log")
(public! 'todo-triage "(todo-triage ID [PROPS]) — move an inbox task to todo")
(public! 'todo-claim "(todo-claim ID WHO) — WHO takes the task and starts it")
(public! 'todo-done "(todo-done ID [RESULT] [WHO]) — close the task as done")
(public! 'todo-cancel "(todo-cancel ID [REASON] [WHO]) — close the task as cancelled")
(public! 'todo-wait "(todo-wait ID REASON [WHO]) — park the task as waiting")
(public! 'todo-review "(todo-review ID SUMMARY [WHO]) — hand the task to a human for an OK")
(public! 'todo-approve "(todo-approve ID [TEXT] [WHO]) — a human approves a task in review")

(domain! 'writing)
(effects! '(read write))

(define *todo-buffer* "*Todos*")

(define (todo--buffers)
  "every live todo list; a group keeps its own"
  (filter (lambda (b) (equal? (buffer-local b 'list-mode) "todo-mode")) (buffer-list-mru)))

(define (todo--list-buffer)
  "the todo list a command acts on: this one, else the one used last"
  (if (equal? (buffer-local (current-buffer) 'list-mode) "todo-mode")
      (current-buffer)
      (let ((bs (todo--buffers))) (and (pair? bs) (car bs)))))

(define (todo--refresh-all!)
  (for-each (lambda (b)
              (if (window-showing b) (list-refresh! b) (buffer-mark-dirty! b 'todo-list)))
            (todo--buffers)))

;; the list and its task page are one app, an instance per group, laid out
;; by role as apps are: the list in one window, the page in the next
(define (todo--app-id group) (string-append "todo:" (or group "none")))

(define (todo--group-buffer mode base group)
  "the MODE buffer GROUP keeps, like chat-menu and ibuffer; made from BASE when it has none"
  (let ((buf (or (find (lambda (b) (and (equal? (buffer-local b 'mode-name) mode) (equal? (buffer-group b) group)))
                       (buffer-list-mru))
                 (let loop ((n 1))
                   (let ((name (if (= n 1) base (string-append base "<" (number->string n) ">"))))
                     (if (buffer-known? name)
                         (loop (+ n 1))
                         (begin (buffer-create name)
                                (when group (buffer-move-to-group! name group))
                                (with-current-buffer name (lambda () (set-mode! mode)))
                                name)))))))
    (when (boundp 'app-claim!)
      (app-claim! buf (todo--app-id group) (if (equal? mode "todo-mode") 'list 'detail)))
    buf))

(define *todo-views*
  (list (list "open" '())
        (list "inbox" '(state "inbox"))
        (list "review" '(state "review"))
        (list "doing" '(state "doing"))
        (list "waiting" '(state "waiting"))
        (list "mine" 'mine)
        (list "overdue" '(overdue #t))
        (list "closed" '(state ("done" "cancelled")))
        (list "all" '(all #t))))

(define (todo--view buf) (list-tab buf "open"))

(define (todo--view-spec buf)
  (let ((s (cadr (assoc (todo--view buf) *todo-views*))))
    (if (equal? s 'mine) (list 'assignee todo-user) s)))

;; `/` narrows by words, all of which must hit: p:PROJECT, s:STATE,
;; @ASSIGNEE, #TAG, !PRIORITY, or any text of the task
(define (todo--match buf t input)
  (let* ((s (lambda (k) (let ((v (plist-get t k))) (if (string? v) v ""))))
         (has? (lambda (hay w) (or (equal? w "") (completion-match? hay w 'substring))))
         (after (lambda (w n) (substring-bytes w n (string-byte-length w))))
         (tags (string-join (or (plist-get t 'tags) '()) " "))
         (hay (string-join (list (s 'title) (s 'project) (s 'state) (s 'assignee) tags
                                 (s 'source) (s 'notes) (s 'id)) " ")))
    (null? (remove (lambda (w)
             (cond ((string-prefix? "p:" w) (has? (s 'project) (after w 2)))
                   ((string-prefix? "s:" w) (has? (s 'state) (after w 2)))
                   ((string-prefix? "@" w) (has? (s 'assignee) (after w 1)))
                   ((string-prefix? "#" w) (has? tags (after w 1)))
                   ((string-prefix? "!" w) (has? (s 'priority) (after w 1)))
                   (else (has? hay w))))
           (string-split input " ")))))

(define *todo-sorts* '("status" "urgency" "deadline" "created"))

(define (todo--sort-by buf) (list-sort buf "status"))

(define (todo--resort ts by)
  "urgency: time-sensitive first, then status. deadline: soonest first, undated last. created: newest first. status: todo-list's own order."
  (cond ((equal? by "urgency")
         (append (filter (lambda (t) (plist-get t 'urgent)) ts)
                 (filter (lambda (t) (not (plist-get t 'urgent))) ts)))
        ((equal? by "deadline")
         (map cadr (sort (map (lambda (t) (list (list (todo--date-num (plist-get t 'deadline))
                                                      (or (plist-get t 'created) ""))
                                                t))
                              ts))))
        ((equal? by "created")
         (reverse (map cadr (sort (map (lambda (t) (list (or (plist-get t 'created) "") t)) ts)))))
        (else ts)))

(define (todo--rows buf)
  (list-keep buf (todo--sections buf (todo--resort (todo-list (todo--view-spec buf)) (todo--sort-by buf)))))

;;; `<` cycles what a section is; a section heading is a row of kind sep
(define *todo-groupings* '("none" "group" "project" "status"))

(define (todo--grouping buf) (or (buffer-local buf 'todo-grouping) "none"))

(define (todo--sep? t) (equal? (plist-get t 'kind) "sep"))

(define (todo--section-of buf t)
  (let ((g (todo--grouping buf)))
    (cond ((equal? g "group") (or (group-name (plist-get t 'group)) "no group"))
          ((equal? g "project") (plist-get t 'project))
          (else (plist-get t 'state)))))

(define (todo--sections buf ts)
  ;; sections come in the order of their first task, so the most urgent leads
  (if (equal? (todo--grouping buf) "none")
      ts
      (let* ((names (fold (lambda (acc t) (let ((n (todo--section-of buf t))) (if (member n acc) acc (append acc (list n)))))
                          '() ts)))
        (apply append
          (map (lambda (n)
                 (cons (list 'kind "sep" 'id (string-append "sep:" n) 'title n)
                       (filter (lambda (t) (equal? (todo--section-of buf t) n)) ts)))
               names)))))

(define (todo--regroup! buf)
  (let* ((g (todo--grouping buf))
         (next (nth (modulo (+ 1 (todo--rank g *todo-groupings*)) (length *todo-groupings*)) *todo-groupings*)))
    (buffer-set-local! buf 'todo-grouping next)
    (list-refresh! buf)
    (message (string-append "Todos grouped by " next))))

;;; `/` picks a group, a project or a status from tabs
(define (todo--filter buf t f)
  (let ((k (car f)) (v (car (cdr f))))
    (cond ((equal? k "group") (equal? (plist-get t 'group) v))
          ((equal? k "project") (equal? (plist-get t 'project) v))
          (else #t))))

(define *todo-facets*
  (list (list 'label "Group" 'kind "group"
              'options (lambda (buf)
                         (let* ((ids (fold (lambda (acc t) (let ((g (plist-get t 'group)))
                                                             (if (or (not g) (member g acc)) acc (cons g acc))))
                                           '()
                                           (todo-list (todo--view-spec buf))))
                                ;; the group the list shows has a name even with no tasks
                                (shown (let ((f (assoc "group" (list-filters buf)))) (and f (cadr f))))
                                (live (filter group-name (if (and shown (not (member shown ids))) (cons shown ids) ids))))
                           (sort (map (lambda (g) (list (group-name g) g)) live)))))
        (list 'label "Project" 'kind "project"
              'options (lambda (buf) (map (lambda (p) (list p p)) (todo-projects))))
        (list 'label "Status" 'kind "status"
              'options (lambda (buf) (map (lambda (v) (list (car v) (car v)))
                                          (remove (lambda (v) (equal? (car v) "all")) *todo-views*)))
              'get (lambda (buf) (let ((v (todo--view buf))) (if (equal? v "all") #f v)))
              'set (lambda (buf v) (list-tab-set! buf (or v "all"))))))

(define (todo--due t)
  (let ((d (plist-get t 'deadline)))
    (cond ((not d) "") ((todo--overdue? t) (string-append d " !")) (else d))))

;; the state, priority, project, dates and tags under the title
(define (todo--meta t)
  (string-join
    (filter (lambda (s) (not (equal? s "")))
            (list (plist-get t 'state)
                  (let ((p (plist-get t 'priority))) (if p (string-append "#" p) ""))
                  (if (plist-get t 'urgent) "urgent" "")
                  (plist-get t 'project)
                  (if (plist-get t 'deadline) (string-append "due " (todo--due t)) "")
                  (if (plist-get t 'scheduled) (string-append "scheduled " (plist-get t 'scheduled)) "")
                  (let ((tags (plist-get t 'tags)))
                    (if (pair? tags) (string-append ":" (string-join tags ":") ":") ""))))
    "  ·  "))

;; each state wears a tinted pill; the dot before the title shares its colour
(defface! 'todo-title 'family "var(--font-sans)" 'size "1.12em" 'weight "500" 'fg "var(--default-fg)")
;; the wide table keeps one font, so its columns stay in line
(defface! 'todo-row-title 'weight "600")
(defface! 'todo-heading 'family "inherit" 'size "1em" 'weight "700" 'fg "var(--default-fg)")
(defface! 'todo-check 'fg "var(--dim-fg)")
;; the group that filed the task wears an outline, not a fill
(defface! 'todo-group 'fg "var(--faint-fg)" 'box "color-mix(in srgb, var(--faint-fg) 55%, transparent)")
(defface! 'todo-project 'fg "var(--accent-fg)" 'bg "color-mix(in srgb, var(--accent-fg) 16%, transparent)")
(defface! 'todo-tags 'fg "var(--dim-fg)" 'bg "var(--hl-line-bg)")
(defface! 'todo-date 'fg "var(--faint-fg)")
(defface! 'todo-overdue 'fg "#e0556b" 'weight "700")
;; a state's hue tints its pill and mixes into the text, so it reads on a dark theme and a light one
(defface! 'todo-state-review 'fg "color-mix(in srgb, #e0556b 75%, var(--default-fg))" 'bg "color-mix(in srgb, #e0556b 20%, transparent)" 'weight "600")
(defface! 'todo-state-doing 'fg "color-mix(in srgb, #e0a040 75%, var(--default-fg))" 'bg "color-mix(in srgb, #e0a040 20%, transparent)" 'weight "600")
(defface! 'todo-state-todo 'fg "color-mix(in srgb, #6b8cff 75%, var(--default-fg))" 'bg "color-mix(in srgb, #6b8cff 20%, transparent)" 'weight "600")
(defface! 'todo-state-inbox 'fg "var(--default-fg)" 'bg "color-mix(in srgb, var(--faint-fg) 22%, transparent)" 'weight "600")
(defface! 'todo-state-waiting 'fg "color-mix(in srgb, #a07ad0 75%, var(--default-fg))" 'bg "color-mix(in srgb, #a07ad0 20%, transparent)" 'weight "600")
(defface! 'todo-state-done 'fg "color-mix(in srgb, #4fa36b 75%, var(--default-fg))" 'bg "color-mix(in srgb, #4fa36b 20%, transparent)" 'weight "600")
(defface! 'todo-state-cancelled 'fg "var(--faint-fg)" 'decoration "line-through")

(define (todo--state-face t)
  (let ((f (string-append "todo-state-" (or (plist-get t 'state) "inbox"))))
    (if (member f (face-list)) f "todo-state-inbox")))

(define (todo--pill t)
  (list (string-append " " (or (plist-get t 'state) "") " ") (todo--state-face t)))

;; the dot before a card's title: the state's hue, without the pill's fill
(for-each (lambda (s)
            (defface! (string->symbol (string-append "todo-dot-" s))
                      'fg (let ((hue (assoc s '(("review" "#e0556b") ("doing" "#e0a040") ("todo" "#6b8cff")
                                                ("waiting" "#a07ad0") ("done" "#4fa36b")))))
                            (if hue (cadr hue) "var(--faint-fg)"))))
          *todo-states*)
(defface! 'todo-agent-live 'fg "#4fa36b")

(define (todo--dot t)
  (let ((s (or (plist-get t 'state) "inbox")))
    (list (if (member s *todo-closed*) "✓" "●") (string-append "todo-dot-" s))))

;; who holds the task, short: a chat says how it is doing, not its id
(define (todo--agent t)
  ;; the chat that holds the task: its state, its title, and how long since
  ;; its last turn moved
  (let* ((a (plist-get t 'assignee))
         (row (and (string? a) (event-view-get 'chat-status a)))
         (running? (and row (member (plist-get row 'status) '(running starting))))
         (chat (todo--chat-of t))
         (at (and row (plist-get row 'at)))
         (label (lambda (state)
                  (string-join (filter (lambda (s) (not (equal? s "")))
                                       (list state
                                             (if chat (format-elide chat 32) "")
                                             (if (and at (not running?)) (format-age (- (current-time) at)) "")))
                               " · "))))
    (cond ((and (todo--blank? a) (not chat)) "")
          ((todo--stalled? t) (list (label (if chat "◌ stalled" "◌ stalled · chat gone")) "todo-overdue"))
          (running? (list (label "● working") "todo-agent-live"))
          ((or chat (string-prefix? "chat:" a)) (list (label (if chat "○ idle" "○ chat closed")) "todo-date"))
          (else (list (string-append "@" a) "org-meta")))))

(define (todo--last-update t)
  ;; the newest log line as "TEXT · AGE ago", without its stamp and author
  (let ((log (plist-get t 'log)))
    (if (not (pair? log))
        ""
        (let* ((line (car (reverse log)))
               (words (string-split line " ")))
          (if (< (length words) 4)
              line
              (let* ((d (map string->number (string-split (car words) "-")))
                     (hm (map string->number (string-split (cadr words) ":")))
                     (when (and (= (length d) 3) (= (length hm) 2) (not (member #f (append d hm)))
                                (parts->time (car d) (cadr d) (caddr d) (car hm) (cadr hm)))))
                (string-append (format-elide (string-join (list-tail words 3) " ") 90)
                               (if when (string-append " · " (format-age (- (current-time) when) 'ago)) ""))))))))

(define *todo-months* '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(define (todo--short-date d)
  ;; 2026-08-21 reads as 21 Aug
  (if (and (string? d) (>= (string-length d) 10))
      (string-append (let ((dd (substring d 8 10))) (if (equal? (substring dd 0 1) "0") (substring dd 1 2) dd))
                     " " (nth (- (string->number (substring d 5 7)) 1) *todo-months*))
      (or d "")))

(define (todo--when t)
  ;; the deadline wins over the scheduled date; an overdue one turns red
  (let ((d (plist-get t 'deadline)) (s (plist-get t 'scheduled)))
    (cond (d (list (string-append "due " (todo--short-date d) (if (todo--overdue? t) " !" ""))
                   (if (todo--overdue? t) "todo-overdue" "todo-date")))
          (s (list (string-append "◷ " (todo--short-date s)) "todo-date"))
          (else ""))))

(define (todo--tag-text t)
  ;; the tags as badges, one cell of pills
  (let ((tags (plist-get t 'tags)))
    (todo--chips (if (pair? tags) (map (lambda (g) (todo--chip g "todo-tags")) tags) '()))))

;; a window this wide shows a task on one line; a narrower one gives the
;; title its own line, so the title is not cut
(define todo-wide-cols 150)

(define (todo--wide-columns buf)
  ;; plain fixed columns, as ibuffer draws them; the title takes what is left
  (list (list "STATE" 7)
        (list "P" 2)
        (list "TODO" #f 'left 'end)
        (list "PROJECT" 14 'left 'end)
        (list "WHO" 24 'left 'end)
        (list "DUE" 12)))

(define (todo--narrow-columns buf)
  ;; a narrow window keeps ibuffer's one line a task, without who and when
  (list (list "STATE" 7)
        (list "P" 2)
        (list "TODO" #f 'left 'end)
        (list "PROJECT" 12 'left 'end)))

(define (todo--narrow-cells buf t)
  (let ((cs (todo--cells buf t)))
    (list (list-ref cs 0) (list-ref cs 1) (list-ref cs 2) (list-ref cs 3))))

(define (todo--short-project t)
  ;; "recruiting:thine" reads as "thine" in a column this narrow
  (let ((p (or (plist-get t 'project) "")))
    (car (reverse (string-split p ":")))))

(define (todo--cells buf t)
  ;; ibuffer's look: plain text, the state in its hue, the rest dim
  (if (todo--sep? t)
      (list "" "" (list (plist-get t 'title) "list-section-name") "" "" "")
  (let ((s (or (plist-get t 'state) "inbox")))
    (list (list s (string-append "todo-dot-" s))
          (list (string-append (if (plist-get t 'urgent) "!" "") (or (plist-get t 'priority) ""))
                (if (plist-get t 'urgent) "todo-overdue" "org-priority"))
          (list (plist-get t 'title) (if (member s *todo-closed*) "f-dim" "ibuffer-name"))
          (list (todo--short-project t) "f-dim")
          ;; a chat that closed leaves only its id behind, which says nothing
          (list (let* ((w (todo--who t))
                       (w (if (string-prefix? "chat:" w) "chat closed" w))
                       (n (length (todo--attached t))))
                  (if (> n 0) (string-append w " +" (number->string n)) w))
                (if (todo--stalled? t) "todo-overdue" "f-dim"))
          (todo--when t)))))

(define (todo--chips parts)
  ;; one cell of pills: PARTS are (TEXT FACE), or "" for none. Answers the
  ;; text and its spans, (OFFSET LENGTH FACE), for a cell to carry.
  (let loop ((ps (filter pair? parts)) (text "") (spans '()))
    (if (null? ps)
        (list text (reverse spans))
        (let* ((pre (if (equal? text "") "" " "))
               (at (+ (string-byte-length text) (string-byte-length pre)))
               (s (car (car ps))))
          (loop (cdr ps) (string-append text pre s)
                (cons (list at (string-byte-length s) (cadr (car ps))) spans))))))

(define (todo--chip s face) (if (todo--blank? s) "" (list (string-append " " s " ") face)))

(define (todo--tags-width buf)
  ;; the tags sit flush right, as wide as the widest of them
  (max 1 (min 40 (apply max (cons 0 (map (lambda (t) (string-length (car (todo--tag-text t))))
                                         (list-entries buf)))))))

(define (todo--row-columns buf)
  ;; a card: a box and the title, which wraps; then the pills on the left
  ;; and the tags flush right; then the last update; then a blank line
  (list (list (list "" 2) (list "TODO" #f 'left 'wrap))
        (list (list "" 2) (list "META" #f 'left 'end) (list "TAGS" (todo--tags-width buf) 'right))
        (list (list "" 2) (list "UPDATE" #f 'left 'end))
        (list (list "" #f 'left 'end))))

(define (todo--row-cells buf t)
  ;; a card: a box and the title; the state, priority, project and group as
  ;; pills, then the date; the tags on the right; under them the chat that
  ;; holds it and the last log line with its age
  (if (todo--sep? t)
      (list (list "" (list (plist-get t 'title) "list-section-name")))
      (let* ((closed? (member (plist-get t 'state) *todo-closed*))
             (who (todo--agent t))
             (due (todo--when t))
             (project (plist-get t 'project))
             (group (group-name (plist-get t 'group)))
             (meta (todo--chips
                     (list (todo--pill t)
                           (todo--chip (plist-get t 'priority) "org-priority")
                           (todo--chip project "todo-project")
                           (if (equal? group project) "" (todo--chip group "todo-group"))
                           (if (pair? due) (list (string-append " " (car due)) (cadr due)) "")))))
        (list (list (todo--dot t) (list (plist-get t 'title) "todo-title"))
              (list "" meta (todo--tag-text t))
              (list "" (todo--chips (list (if (pair? who) (todo--chip (car who) (cadr who)) "")
                                        (todo--chip (todo--attached-text t) "todo-date")
                                        (todo--chip (todo--last-update t) "org-meta"))))
              (list "")))))

(define (todo--at) (let ((t (list-current (todo--list-buffer)))) (and t (not (todo--sep? t)) t)))

(define (todo--keep-place! f)
  "run F, which may change the task at point, and redraw. A task whose state changes moves in the urgency order; point stays where the reader was, on the task that followed it, so working down the inbox does not lose the place"
  (let* ((buf (todo--list-buffer))
         (i (list-index buf))
         (es (list-entries buf))
         (key (and i (< i (length es)) (list-key buf (nth i es))))
         (next (and i (< (+ i 1) (length es)) (list-key buf (nth (+ i 1) es)))))
    (f)
    (list-refresh! buf)
    (let* ((rows (list-entries buf))
           (moved? (not (equal? i (and key (list-index-of buf rows key)))))
           (j (and moved? next (list-index-of buf rows next))))
      (when j (list-goto-index! buf j)))))

(define (todo--with-row f)
  (let ((t (todo--at)))
    (if t
        (todo--keep-place! (lambda () (f t)))
        (message "No task at point"))))

(define (todo--marked-tasks)
  "the marked tasks the list shows, in list order"
  (let* ((buf (todo--list-buffer))
         (keys (list-marked buf *list-mark-char*)))
    (filter (lambda (t) (and (not (todo--sep? t)) (member (plist-get t 'id) keys)))
            (list-entries buf))))

(define (todo--with-tasks verb f)
  "run F on each marked task once the reader says yes to VERB, else on the task at point"
  (let ((ts (todo--marked-tasks)))
    (if (pair? ts)
        (yes-or-no? (string-append verb " " (number->string (length ts)) " marked tasks? ")
          (lambda (ok)
            (when ok
              (todo--keep-place!
                (lambda ()
                  (list-clear-marks! (todo--list-buffer))
                  (for-each f ts))))))
        (todo--with-row f))))

(define (todo--set-at! k v)
  (todo--with-tasks (string-append "Set the " (symbol->string k) " to " v " for")
    (lambda (t) (todo-update (plist-get t 'id) (list k v)))))

(define (todo--ask-at! prompt k)
  (if (or (todo--at) (pair? (todo--marked-tasks)))
      (read-string prompt
        (lambda (s)
          (todo--with-tasks (string-append "Set the " (symbol->string k) " of")
            (lambda (t) (todo-update (plist-get t 'id) (list k s))))))
      (message "No task at point")))

(define-command "todo-visit" "Open the task's file at its heading"
  (lambda ()
    (let ((t (todo--at)))
      (if t
          (begin (visit (plist-get t 'file)) (goto-char! (plist-get t 'pos)))
          (message "No task at point")))))

(define-command "todo-accept" "Mark the task todo: triage it, or approve it from review"
  (lambda () (todo--set-at! 'state "todo")))
(define-command "todo-mark-done" "Mark the task done"
  (lambda () (todo--set-at! 'state "done")))
(define-command "todo-mark-cancelled" "Cancel the task"
  (lambda () (todo--set-at! 'state "cancelled")))
(define-command "todo-mark-waiting" "Park the task as waiting"
  (lambda () (todo--set-at! 'state "waiting")))
(define-command "todo-mark-doing" "Mark the task in progress"
  (lambda () (todo--set-at! 'state "doing")))

(define-command "todo-toggle-urgent" "Mark the task time-sensitive, or not"
  (lambda ()
    (todo--with-tasks "Toggle urgent on"
      (lambda (t)
        (todo-update (plist-get t 'id) (list 'urgent (not (plist-get t 'urgent))))))))

(define-command "todo-cycle-priority" "Cycle the task's priority: A, B, C, none"
  (lambda ()
    (todo--with-tasks "Cycle the priority of"
      (lambda (t)
        (let ((p (plist-get t 'priority)))
          (todo-update (plist-get t 'id)
                       (list 'priority (cond ((not p) "A") ((equal? p "A") "B") ((equal? p "B") "C") (else #f)))))))))

;; assigning hands the task to a fresh chat in a group: the chat is the
;; assignee, and its first message is the brief
(define (todo--brief t chat)
  (let* ((id (plist-get t 'id))
         (field (lambda (label k) (let ((v (plist-get t k)))
                                    (if (todo--blank? v) "" (string-append label ": " v "\n")))))
         (notes (plist-get t 'notes)))
    (string-append
     "You are assigned todo " id ": " (plist-get t 'title) "\n\n"
     (field "Project" 'project) (field "Deadline" 'deadline) (field "Source" 'source)
     (if (todo--blank? notes) "" (string-append "\nNotes:\n" notes "\n"))
     "\nRead it with (todo-get \"" id "\"). Work it through the todo API as \"" chat "\":\n"
     "- (todo-log \"" id "\" TEXT \"" chat "\") for progress\n"
     "- (todo-review \"" id "\" SUMMARY \"" chat "\") before anything goes out, and stop there\n"
     "- (todo-wait \"" id "\" REASON \"" chat "\") when it waits on someone\n"
     "  then (agent-listen! '(topic \"whatsapp:PHONE\" kind received task \"" id "\") NOTE), so the reply wakes you; a mail:ACCOUNT topic needs 'match with the sender\n"
     "- (todo-done \"" id "\" RESULT \"" chat "\") when it is finished\n"
     "If you saved files, call (jj-describe! TEXT) before todo-review or todo-done; TEXT follows docs/COMMITS.md.\n"
     "Never end a turn while you wait on background work (tests, a task) without a wake-up: first (agent-listen! '(at \"YYYY-MM-DD HH:MM\") NOTE), or a listener on the event you wait for. Else nothing wakes you.\n"
     "When done, close this chat with (run-command \"chat-dismiss\").\n")))

(define (todo-assign-chat! id group &optional who)
  "(todo-assign-chat! ID GROUP [WHO]) — hand the task to its chat in GROUP (assign-chat!: its live assignee chat unless that is the caller, else a new one), make that chat the assignee and send it the brief when the chat is new; a new chat is the calling chat's subagent with notify; return the chat"
  (let* ((t (todo--must id))
         (g (or (group-resolve-id group) (group-ensure-record! group)))
         ;; the chat whose eval starts the task, if any
         (caller (subagent-spawner))
         ;; the task's own chat is its live assignee, never the chat that
         ;; last logged on it: that one can be the orchestrator, the caller
         (own (let ((a (plist-get t 'assignee)))
                (and (string? a) (string-prefix? "chat:" a) (todo--live-chat a))))
         (held (and own (not (and caller (equal? (subagent-slug own) caller))) own)))
    (let* ((got (assign-chat! #f g
                  (lambda (chat)
                    ;; a new chat is the caller's subagent: the caller hears
                    ;; when it stops
                    (when caller
                      (subagent-record! caller chat)
                      (buffer-set-local! chat 'subagent-notify #t))
                    (todo-update id (list 'assignee (chat-stable-id! chat)
                                          'chats (todo--chats-keeping t (plist-get t 'assignee))
                                          'state (if (member (plist-get t 'state) '("inbox" "todo")) "doing" (plist-get t 'state))
                                          'log (string-append "assigned to a chat in " (group-name g))
                                          'by (or who todo-user)))
                    (todo--brief (todo-get id) (chat-stable-id! chat)))
                  held))
           (chat (car got)))
      ;; A new chat wears the task's title. Named here, after the brief went
      ;; out under the old name; the first-prompt title lands later and
      ;; leaves a titled chat alone.
      (if (and (cadr got) (string? (plist-get t 'title)))
          (let ((sid (chat-stable-id! chat)))
            (if (chat-title chat (plist-get t 'title))
                ;; chat-title may have settled on "Title<2>"; find the renamed
                ;; buffer by its stable id
                (or (find (lambda (b) (and (string? (buffer-local b 'chat-title))
                                           (equal? (chat-stable-id! b) sid)))
                          (group-buffers g))
                    chat)
                chat))
          chat))))

;; the assignee of a chat-held task is the chat's stable id, since the
;; chat renames itself after its first answer
(define (todo--chat-id who)
  ;; "chat:A:B" as it is; the agent form "agent:chat-A-B" as "chat:A:B"
  (cond ((string-prefix? "chat:" who) who)
        ((string-prefix? "agent:chat-" who)
         (let ((parts (string-split (substring who 11 (string-length who)) "-")))
           (and (= (length parts) 2) (string-append "chat:" (car parts) ":" (cadr parts)))))
        (else #f)))

;; every card asks which buffer is a chat, often once per log line, so one
;; walk of the buffers answers a whole draw; it is kept for a second
(define *todo-chat-index* #f)

(define (todo--chat-index)
  (let ((now (monotonic-ms)))
    (if (and *todo-chat-index* (< (- now (car *todo-chat-index*)) 1000))
        (cdr *todo-chat-index*)
        (let ((ix (reverse (fold (lambda (acc b)
                                   ;; a chat read back from its file keeps only its slug
                                   (let* ((slug (buffer-local b 'agent-slug))
                                          (id (or (buffer-local b 'chat-id)
                                                  (and (string? slug) (string-prefix? "chat-" slug)
                                                       (string-append "chat:" (string-join (cdr (string-split slug "-")) ":"))))))
                                     (if (string? id) (cons (list id b) acc) acc)))
                                 '() (buffer-list)))))
          (set! *todo-chat-index* (cons now ix))
          ix))))

(define (todo--live-chat id)
  (and (string? id)
       (let ((hit (assoc id (todo--chat-index))))
         (and hit (buffer-exists? (cadr hit)) (cadr hit)))))

(define (todo--chat-of t)
  ;; the assignee while it is live, else the last live chat the log names:
  ;; a chat that moved the task to review is the one that worked it
  (let ((a (plist-get t 'assignee)))
  ;; a task assigned to a chat is that chat's, even when the chat is gone
  (if (and (string? a) (string-prefix? "chat:" a))
      (todo--live-chat a)
      (todo--first (lambda (x) x)
        (map (lambda (line)
               (let ((words (string-split line " ")))
                 ;; the chat that filed or assigned the task did not work it
                 (and (>= (length words) 4)
                      (not (member (list-ref words 3) '("created" "assignee" "assigned")))
                      (todo--live-chat (todo--chat-id (caddr words))))))
             (reverse (or (plist-get t 'log) '())))))))

(define (todo--archived-chat a)
  ;; the .chat file of the chat "chat:SECS:N": its file is stamped a moment
  ;; after the chat was made, and its header names the slug
  (let* ((parts (string-split a ":"))
         (secs (and (= (length parts) 3) (string->number (cadr parts))))
         (slug (string-append "chat-" (cadr parts) "-" (caddr parts))))
    (and secs
         (todo--first
           (lambda (p)
             (let* ((leaf (car (reverse (string-split p "/"))))
                    (stamp (string->number (car (string-split leaf "-")))))
               (and stamp (<= secs stamp) (< stamp (+ secs 86400))
                    (equal? slug (plist-get (cadr (memq 'header (chat-log-read p))) 'slug))
                    p)))
           (chat-log-files)))))

(define (todo--chat-title path)
  (plist-get (cadr (memq 'header (chat-log-read path))) 'title))

(define (todo--open-chat c group)
  ;; the chat whose id is C: live, else its archived conversation read back
  ;; in GROUP, else #f
  (or (todo--live-chat c)
      (let ((path (todo--archived-chat c)))
        (and path
             ;; name it after its title now, as chat-restore does, and find it by its id
             (let ((buf (visit-in-group path group))
                   (title (todo--chat-title path)))
               (when (and buf (string? title)) (chat-title buf title))
               (set! *todo-chat-index* #f)
               (todo--live-chat c))))))

(define (todo--revive-chat t)
  ;; the task's chat: live, else its archived conversation read back in the
  ;; task's group, else #f
  (or (todo--chat-of t)
      (let ((a (plist-get t 'assignee)))
        (and (string? a) (string-prefix? "chat:" a)
             (todo--open-chat a (or (todo--home-group t) (frame-group)))))))

(define (todo--chat-ref chat)
  ;; a chat's id, from the id itself or from its buffer
  (cond ((not (string? chat)) #f)
        ((string-prefix? "chat:" chat) chat)
        ((buffer-known? chat) (chat-stable-id! chat))
        (else #f)))

(define (todo--chats-keeping t c)
  ;; the task's attached chats with C among them, when C is a chat
  (let ((cs (or (plist-get t 'chats) '())))
    (if (and (string? c) (string-prefix? "chat:" c) (not (member c cs)))
        (append cs (list c))
        cs)))

(define (todo-chats t)
  "(todo-chats TASK) — the ids of the task's chats: the assignee first, then the attached ones"
  (let ((a (plist-get t 'assignee)))
    (fold (lambda (acc c) (if (member c acc) acc (append acc (list c))))
          '()
          (append (if (and (string? a) (string-prefix? "chat:" a)) (list a) '())
                  (or (plist-get t 'chats) '())))))

(define (todo-attach-chat! id chat &optional who)
  "(todo-attach-chat! ID CHAT [WHO]) — attach CHAT, a chat buffer or its id, to the task beside its assignee; return the task"
  (let* ((t (todo--must id)) (c (todo--chat-ref chat)))
    (cond ((not c) (todo--fail "not a chat: " chat))
          ((member c (todo-chats t)) t)
          (else (todo-update id (list 'chats (todo--chats-keeping t c) 'by (or who todo-user)))))))

(define (todo-detach-chat! id chat &optional who)
  "(todo-detach-chat! ID CHAT [WHO]) — take CHAT off the task's attached chats; the assignee stays; return the task"
  (let* ((t (todo--must id)) (c (todo--chat-ref chat)))
    (todo-update id (list 'chats (remove (lambda (x) (equal? x c)) (or (plist-get t 'chats) '()))
                          'by (or who todo-user)))))

(public! 'todo-chats "(todo-chats TASK) — the ids of the task's chats: the assignee first, then the attached ones")
(public! 'todo-attach-chat! "(todo-attach-chat! ID CHAT [WHO]) — attach a chat, its buffer or id, to the task beside its assignee")
(public! 'todo-detach-chat! "(todo-detach-chat! ID CHAT [WHO]) — take a chat off the task's attached chats")

(define (todo--chat-label c)
  ;; a live chat's name, else its archived title, else its id
  (or (todo--live-chat c)
      (let* ((path (todo--archived-chat c)) (title (and path (todo--chat-title path))))
        (and path (string-append (or title c) "  (archived)")))
      (string-append c "  (gone)")))

(define (todo--pick-chat! t)
  ;; one chat goes straight there; several ask which
  (let ((cs (todo-chats t)) (g (or (todo--home-group t) (frame-group))))
    (define (go! c)
      (let ((buf (todo--open-chat c g)))
        (if buf (todo--show-chat! buf) (message "That chat is gone"))))
    (cond ((null? cs) (message "The task has no chat"))
          ((null? (cdr cs)) (go! (car cs)))
          (else
            (let ((labels (map (lambda (c) (list (todo--chat-label c) c)) cs)))
              (minibuffer-read* "Chat: " (map car labels)
                (list (list 'confirm (lambda (l) (let ((hit (assoc l labels))) (when hit (go! (cadr hit)))))))))))))

(define (todo--attach-read! t after)
  ;; ask for an open chat not yet on the task, and attach it
  (let* ((have (todo-chats t))
         (open (filter (lambda (row) (not (member (car row) have))) (todo--chat-index))))
    (if (null? open)
        (message "No other open chat")
        (minibuffer-read* "Attach chat: " (map cadr open)
          (list (list 'confirm
                      (lambda (name)
                        (let ((row (find (lambda (r) (equal? (cadr r) name)) open)))
                          (when row
                            (todo-attach-chat! (plist-get t 'id) (car row))
                            (after)
                            (message (string-append "Attached " name)))))))))))

(define-command "todo-attach-chat" "Attach another open chat to the task at point, beside the one it is assigned to"
  (lambda ()
    (let ((t (todo--at)))
      (if t (todo--attach-read! t (lambda () #t)) (message "No task at point")))))

(define-command "todo-detail-attach-chat" "Attach another open chat to this task, beside the one it is assigned to"
  (lambda ()
    (let* ((buf (current-buffer)) (t (todo--detail-task buf)))
      (if t (todo--attach-read! t (lambda () (todo--detail-render! buf))) (message "The task is gone")))))

(define-command "todo-attach-this-chat" "Attach the chat you are in to an open task"
  (lambda ()
    (let* ((chat (current-buffer))
           (c (and (buffer-local chat 'agent-slug) (todo--chat-ref chat)))
           (rows (map (lambda (t) (list (string-append (plist-get t 'title) "  ·  " (plist-get t 'id)) (plist-get t 'id)))
                      (todo-list))))
      (if (not c)
          (message "Not in a chat")
          (minibuffer-read* "Attach this chat to task: " (map car rows)
            (list (list 'confirm
                        (lambda (l)
                          (let ((hit (assoc l rows)))
                            (when hit
                              (todo-attach-chat! (cadr hit) c)
                              (message (string-append "Attached to " (car hit)))))))))))))

(define (todo--who t) (or (todo--chat-of t) (plist-get t 'assignee) ""))

(define (todo--attached t)
  ;; the chats attached beside the assignee, by title while they live
  (map (lambda (c) (or (todo--live-chat c) "chat closed"))
       (remove (lambda (c) (equal? c (plist-get t 'assignee))) (todo-chats t))))

(define (todo--attached-text t)
  (let ((more (todo--attached t)))
    (if (null? more) ""
        (string-append "+ " (string-join (map (lambda (c) (format-elide c 24)) more) ", ")))))

;; a card says how its chat is doing. The event log's chat-status view
;; knows it; the todo file does not hold it.
;; a task a chat holds has stalled when it is still in doing but the chat
;; is not working on it: the turn ended, or the chat is gone, without a
;; review, wait or done
(define (todo--stalled? t)
  (let ((a (plist-get t 'assignee)))
    (and (equal? (plist-get t 'state) "doing")
         (string? a) (string-prefix? "chat:" a)
         (let ((row (event-view-get 'chat-status a)))
           (not (and row (member (plist-get row 'status) '(running starting))))))))

(define (todo--status t)
  (let* ((a (plist-get t 'assignee))
         (row (and (string? a) (event-view-get 'chat-status a))))
    (if (not row)
        (if (todo--stalled? t) "stalled · chat gone" "")
        (let ((status (plist-get row 'status))
              (stop (plist-get row 'stop-reason)))
          (string-append (if (todo--stalled? t) "stalled · " "")
                         (if status (chats-state-label status) "turn ended")
                         (if (and stop (not (agent-turn-end-normal? stop)))
                             (string-append " (" stop ")")
                             "")
                         " " (format-time (plist-get row 'at) "%H:%M"))))))

(define (todo--who-status t)
  (let ((who (todo--who t)) (status (todo--status t)))
    (cond ((equal? status "") who)
          ((equal? who "") status)
          (else (string-append who "  ·  " status)))))

;; a task's chat goes where chats live: the pane already showing one, so
;; the list and its page stay put. Without a chat pane it takes this window
(define (todo--show-chat! chat)
  (let ((id (group-home-of chat)))
    (when (and id (not (equal? id (frame-group)))) (switch-to-group! id)))
  (let ((shown (window-showing chat))
        (pane (window-showing-mode "chat-mode" #f)))
    (cond ((and shown (window-exists? shown)) (select-window! shown))
          (pane (display-buffer-in-window! pane chat) (select-window! pane))
          (else (switch-to-buffer! chat)))
    chat))

(define-command "todo-goto-chat" "Go to the chat the task is assigned to; with several, ask which"
  (lambda ()
    (let* ((t (todo--at)) (chat (and t (todo--chat-of t))))
      (cond ((not t) (message "No task at point"))
            ((pair? (todo-chats t)) (todo--pick-chat! t))
            (chat (todo--show-chat! chat))
            (else (message "The task is not with a live chat"))))))

;; one task as its own page beside the list. Its chat is the assignee, the
;; chat that works the task, never the one that filed it
(define *todo-detail-buffer* "*Todo*")

(define (todo--detail-group)
  (let ((l (todo--list-buffer))) (or (and l (buffer-group l)) (group-here))))

(define (todo--detail-buffer)
  "the task page of the group you are in, or #f; a group keeps its own"
  (let ((group (todo--detail-group)))
    (find (lambda (b) (and (equal? (buffer-local b 'mode-name) "todo-detail-mode") (equal? (buffer-group b) group)))
          (buffer-list-mru))))

(define (todo--detail-task buf)
  (let ((id (buffer-local buf 'todo-id)))
    (and id (todo-get id))))

(define (todo--detail-tone state)
  (cond ((equal? state "doing") "warn")
        ((equal? state "review") "info")
        ((equal? state "done") "good")
        ((equal? state "cancelled") "bad")
        (else "")))

;; the facts under the title: project, priority, when it is due, when filed
(define (todo--detail-facts t)
  (let* ((p (plist-get t 'priority))
         (d (plist-get t 'deadline))
         (s (plist-get t 'scheduled))
         (segs (filter pair?
                 (list (let ((pr (plist-get t 'project))) (and (not (todo--blank? pr)) (list "" pr)))
                       (and p (list "c-badge" p))
                       (and (plist-get t 'urgent) (list "c-warn" "urgent"))
                       (and d (list (if (todo--overdue? t) "c-warn" "")
                                    (string-append "due " (todo--short-date d) (if (todo--overdue? t) " — overdue" ""))))
                       (and s (list "" (string-append "scheduled " (todo--short-date s))))
                       (let ((c (plist-get t 'created))) (and c (list "" (string-append "filed " (todo--short-date c)))))))))
    (let loop ((xs segs) (out '()))
      (cond ((null? xs) (reverse out))
            ((null? out) (loop (cdr xs) (list (car xs))))
            (else (loop (cdr xs) (cons (car xs) (cons '("c-sep" "  ·  ") out))))))))

;; a log line is "YYYY-MM-DD HH:MM WHO TEXT": its when and who head the text
(define (todo--detail-entry line)
  (let ((ws (string-split line " ")))
    (if (< (length ws) 4)
        (component 'ui/bullet (list 'text line))
        (component 'ui/group
          (list 'body
                (list (component 'ui/meta
                        (list 'segs (list (list "" (string-append (todo--short-date (car ws)) " " (cadr ws)))
                                          '("c-sep" "  ·  ")
                                          (list "" (caddr ws)))))
                      (list 'tag "c-text" 'text (string-join (list-tail ws 3) " "))))))))

;; what the task's agent waits for: the listeners agent-listen! made for
;; the task, or for its chat when they name no task
(define (todo--listeners t)
  (if (not (boundp 'agent-listeners))
      '()
      (let ((chat (let ((b (todo--chat-of t))) (and b (buffer-local b 'chat-id)))))
        (filter (lambda (l)
                  (if (todo--blank? (plist-get l 'task))
                      (and chat (equal? (plist-get l 'chat) chat))
                      (equal? (plist-get l 'task) (plist-get t 'id))))
                (agent-listeners)))))

(define (todo--detail-listener l)
  (let ((match (plist-get l 'match)) (kind (plist-get l 'kind)) (at (plist-get l 'created)))
    (component 'ui/group
      (list 'body
            (list (component 'ui/meta
                    (list 'segs (filter pair?
                                  (list (list "" (plist-get l 'topic))
                                        (and kind '("c-sep" "  ·  ")) (and kind (list "" kind))
                                        (and (not (todo--blank? match)) '("c-sep" "  ·  "))
                                        (and (not (todo--blank? match)) (list "" (string-append "holding " match)))
                                        (and at '("c-sep" "  ·  "))
                                        (and at (list "" (string-append "since " (format-time at "%d %b %H:%M"))))
                                        (and (plist-get l 'keep) '("c-sep" "  ·  "))
                                        (and (plist-get l 'keep) (list "" "keeps listening"))))))
                  (list 'tag "c-text" 'text (or (plist-get l 'note) "")))))))

(define (todo--detail-blocks t)
  ;; (TEXT BLOCKS): every part of the page is one line of TEXT and an anchor
  ;; on it, so the arrows walk the page part by part and it scrolls along
  (let* ((chat (todo--chat-of t))
         (logs (or (plist-get t 'log) '()))
         (notes (plist-get t 'notes))
         (tags (plist-get t 'tags))
         (state (or (plist-get t 'state) "inbox"))
         (lines '())
         (line! (lambda (text) (set! lines (cons text lines)) (length lines)))
         (stop (lambda (blk name first last) (append blk (list 'anchor-name name 'lines (list first last)))))
         (pair (lambda (k v) (if (todo--blank? v) '() (list (list k v)))))
         (part (lambda (title name blks)
                 ;; a titled group: its heading is a line, and each of BLKS one more
                 (let* ((first (line! title))
                        (body (let loop ((bs blks) (i 1) (acc '()))
                                (if (null? bs) (reverse acc)
                                    (loop (cdr bs) (+ i 1)
                                          (cons (let ((n (line! name))) (stop (car bs) (string-append name " " (number->string i)) n n)) acc))))))
                   (stop (component 'ui/group (list 'title title 'body body)) name first (length lines)))))
         (head (let ((n (line! (plist-get t 'title))))
                 (stop (component 'ui/title (list 'text (plist-get t 'title) 'badge state 'tone (todo--detail-tone state))) "Title" n n)))
         (notes-part (if (todo--blank? notes) '()
                         (let ((n (line! "Notes")))
                           (list (stop (component 'ui/group
                                         (list 'title "Notes" 'body (list (list 'tag "c-group" 'class "c-prose c-lines" 'text notes))))
                                       "Notes" n n)))))
         (details (let ((n (line! "Details")))
                    (stop (component 'ui/group
                            (list 'title "Details"
                                  'body
                                  (list
                                    (component 'ui/kv
                                      (list 'pairs
                                        (append
                                          (pair "Chat" (if chat (string-append chat "  ·  a goes there") (plist-get t 'assignee)))
                                          (pair "Also" (let ((more (remove (lambda (c) (equal? c (plist-get t 'assignee))) (todo-chats t))))
                                                         (if (null? more) ""
                                                             (string-append (string-join (map (lambda (c) (or (todo--live-chat c) c)) more) ", ")
                                                                            "  ·  w picks, C attaches"))))
                                          (pair "Status" (todo--status t))
                                          (pair "Group" (group-name (plist-get t 'group)))
                                          (pair "Filed by" (plist-get t 'by))
                                          (pair "Source" (plist-get t 'source))
                                          (pair "Created" (plist-get t 'created))
                                          (pair "Id" (plist-get t 'id))))))))
                          "Details" n n)))
         (listening (let ((ls (todo--listeners t)))
                      (if (null? ls) '()
                          (list (part (string-append "Listening  ·  " (number->string (length ls))) "Listening"
                                      (map todo--detail-listener ls))))))
         (log (if (null? logs) '()
                  (list (part (string-append "Log  ·  " (number->string (length logs))) "Log"
                              (map todo--detail-entry (reverse logs)))))))
    (list
      (string-join (reverse lines) "\n")
      (list
        (component 'ui/page
          (list 'body
            (append
              (list head (component 'ui/meta (list 'segs (todo--detail-facts t))))
              (if (pair? tags) (list (component 'ui/chips (list 'items tags))) '())
              notes-part
              (list details)
              listening
              log)))))))

(define (todo--detail-render! buf)
  (let* ((t (todo--detail-task buf))
         (page (and t (todo--detail-blocks t)))
         (text (if page (car page) ""))
         (line (car (buffer-line-at-point buf))))
    (buffer-set-read-only! buf #f)
    (buffer-set-text! buf text #t)
    (buffer-goto-line! buf (max 1 line))
    (buffer-set-local! buf 'render-mode "blocks")
    (buffer-set-local! buf 'render-blocks
      (if page
          (cadr page)
          (list (component 'ui/empty (list 'text "The task is gone")))))
    (if page (anchor-set-blocks! buf text (cadr page)) (anchor-clear! buf))
    (unless (minor-mode-on? buf "anchor-mode") (enable-minor-mode! buf "anchor-mode"))
    (anchor-sync! buf)
    ;; the page's keys: the same keys bar the list carries
    (buffer-set-local! buf 'footer-line-blocks
      (list (component 'ui/keys-bar
              (list 'main '(("a" "agent") ("e" "file") ("g" "refresh") ("q" "quit"))))))
    (buffer-set-read-only! buf #t)
    buf))

(define (todo-show-detail! id)
  (let ((buf (todo--group-buffer "todo-detail-mode" *todo-detail-buffer* (todo--detail-group))))
    (buffer-set-local! buf 'todo-id id)
    (todo--detail-render! buf)
    (display-buffer-detail! buf (todo--list-buffer))
    buf))
;; highlighting a row also brings up its chat, where chats live, without
;; taking focus: the pane already showing a chat, else a spare window, else
;; a split under the task's page


(define-command "todo-show" "Show the task as its own page beside the list"
  (lambda ()
    (let ((t (todo--at)))
      (if t (todo-show-detail! (plist-get t 'id)) (message "No task at point")))))

(define-command "todo-detail-goto-chat" "Go to the chat working this task; with several, ask which"
  (lambda ()
    (let* ((t (todo--detail-task (current-buffer))) (chat (and t (todo--chat-of t))))
      (cond ((not t) (message "The task is gone"))
            ((pair? (todo-chats t)) (todo--pick-chat! t))
            (chat (todo--show-chat! chat))
            ((plist-get t 'assignee) (message "The task's chat is not live"))
            (else (message "The task is not assigned to a chat"))))))

(define-command "todo-detail-agent" "Go to the agent working this task; start one in the group that filed it, else the group you are in, when none is live"
  (lambda ()
    (let* ((buf (current-buffer))
           (t (todo--detail-task buf))
           (chat (and t (todo--revive-chat t)))
           (here (or (and t (todo--home-group t)) (group-here))))
      (define (start! g)
        (let ((new (todo-assign-chat! (plist-get t 'id) g)))
          (todo--detail-render! buf)
          (todo--show-chat! new)
          (message (string-append "Assigned to " new))))
      (cond ((not t) (message "The task is gone"))
            (chat (todo--show-chat! chat))
            (here (start! here))
            (else (group-read-or-create! "Start an agent in group: " start!))))))

(define-command "todo-detail-visit" "Open the task's file at its heading"
  (lambda ()
    (let ((t (todo--detail-task (current-buffer))))
      (if t
          (begin (visit (plist-get t 'file)) (goto-char! (plist-get t 'pos)))
          (message "The task is gone")))))

(define-command "todo-detail-refresh" "Read the task again"
  (lambda () (todo--detail-render! (current-buffer))))

(define (todo--detail-setup!)
  (desktop-skip! (current-buffer) 'render-blocks)
  (desktop-skip! (current-buffer) 'footer-line-blocks)
  (todo--detail-render! (current-buffer)))

(define-mode "todo-detail-mode" todo--detail-setup!)
(mode-put! "todo-detail-mode" 'chat-follow? #t)
(mode-put! "todo-detail-mode" 'chat-subject "todos")
(mode-put! "todo-detail-mode" 'agent-chat
  (lambda (buf) (let ((t (todo--detail-task buf))) (and t (todo--chat-of t)))))

;; the gutter would count the text's lines, not the tasks, so the list and
;; the page draw none
(define (todo--no-line-numbers!) (buffer-set-local! (current-buffer) 'line-numbers "off"))
(add-hook! 'todo-mode-hook 'todo--no-line-numbers!)
(add-hook! 'todo-detail-mode-hook 'todo--no-line-numbers!)

(mode-keys! "todo-detail-mode"
  '(("a" "todo-detail-agent")
    ("w" "todo-detail-goto-chat")
    ("C" "todo-detail-attach-chat")
    ("e" "todo-detail-visit")
    ("M-o" "todo-detail-task-chat")
    ("g" "todo-detail-refresh")
    ("q" "quit-window")))

(mode-doc! "todo-detail-mode"
  "One task as its own page: state, the chat working it, notes and log. `a` goes to that chat, the one fixing the task, not the one that filed it, and starts one in the group you are in when none is live; `w` only goes. `e` opens the task's file, `g` reads it again, `q` puts it away.")

(define (todo-spawn-chat! group title)
  "(todo-spawn-chat! GROUP TITLE) — file TITLE as a task and hand it to a new chat in GROUP. Nothing is shown and the focus stays: the task is the marker that comes back to the user in review. Return (ID CHAT)"
  (let* ((g (or (group-resolve-id group) (group-ensure-record! group)))
         (name (group-name g))
         (id (todo-create title (list 'project (if (member name (todo-projects)) name todo-default-project)
                                      'state "todo" 'group g)))
         (first? (not (group-primary-chat g)))
         (chat (todo-assign-chat! id g)))
    ;; a group made here has no chat yet: this one becomes its chat pane
    (when first? (group-record-update! g 'primary-chat-id (chat-stable-id! chat)))
    (list id chat)))

(public! 'todo-spawn-chat! "(todo-spawn-chat! GROUP TITLE) — file a task and hand it to a new chat in GROUP without showing it; answers (ID CHAT)")

(define-command "todo-assign" "Hand the task, or each marked task, to a new chat in the group that filed it, else the group you are in; one task goes to its chat in the chat pane, the chat it already has when it has one; C-u asks for the group"
  (lambda ()
    (let* ((t (todo--at))
           (marked (todo--marked-tasks))
           (ask? (and (current-prefix-arg) #t))
           (here (or (and t (todo--home-group t)) (group-here))))
      (define (assign! t g)
        (let ((chat #f))
          (todo--keep-place! (lambda () (set! chat (todo-assign-chat! (plist-get t 'id) g))))
          chat))
      (define (assign-one! g)
        (let ((chat (assign! t g)))
          (todo--show-chat! chat)
          (message (string-append "Assigned to " chat))))
      (define (assign-marked! g)
        (list-clear-marks! (todo--list-buffer))
        (for-each (lambda (m) (assign! m (or g (todo--home-group m) (group-here)))) marked)
        (message (string-append "Assigned " (number->string (length marked)) " tasks to new chats")))
      (cond ((pair? marked)
             (yes-or-no? (string-append "Assign " (number->string (length marked)) " marked tasks to new chats? ")
               (lambda (ok)
                 (when ok
                   (if (or ask? (not (group-here)))
                       (group-read-or-create! "Assign to new chats in group: " assign-marked!)
                       (assign-marked! #f))))))
            ((not t) (message "No task at point"))
            ((and (not ask?) (todo--revive-chat t))
             (todo--show-chat! (todo--revive-chat t)))
            ((or ask? (not here))
             (group-read-or-create! "Assign to a new chat in group: "
               (lambda (g) (assign-one! g))))
            (else (assign-one! here))))))
(define (todo--task-chat! t)
  (if (todo--revive-chat t)
      (todo--show-chat! (todo--revive-chat t))
      (let ((here (or (todo--home-group t) (group-here))))
        (define (start! g)
          (let ((chat #f))
            (todo--keep-place! (lambda () (set! chat (todo-assign-chat! (plist-get t 'id) g))))
            (when (plist-get t 'parent) (todo-attach-chat! (plist-get t 'parent) chat))
            (todo--show-chat! chat)))
        (if here (start! here) (group-read-or-create! "Start a chat in group: " start!)))))

(define-command "todo-task-chat" "Open the task's chat, or start one titled with the task; the chat is also attached to the task's parent"
  (lambda () (let ((t (todo--at))) (if t (todo--task-chat! t) (message "No task at point")))))

(define-command "todo-detail-task-chat" "Open this task's chat, or start one titled with the task; the chat is also attached to the task's parent"
  (lambda () (let ((t (todo--detail-task (current-buffer)))) (if t (todo--task-chat! t) (message "The task is gone")))))

;; a card follows its chat: an event on a chat topic redraws the list
;; when a window shows it, and marks it dirty when none does
(define (todo--on-chat-event e)
  (for-each (lambda (b)
              (if (window-showing b)
                  (debounce! (string->symbol (string-append "todo-cards:" b)) 250 (lambda (_) (list-redraw! b)) #f)
                  (buffer-mark-dirty! b 'todo-cards)))
            (todo--buffers)))

(define (todo--on-refresh! b keys)
  (cond ((memq 'todo-list keys) (list-refresh! b))
        ((memq 'todo-cards keys) (list-redraw! b))))

(event-subscribe! "todo-cards" "chat:*" 'todo--on-chat-event)
(add-hook! 'buffer-refresh-hook 'todo--on-refresh!)

(define-command "todo-set-deadline" "Set the task's deadline: YYYY-MM-DD, today, tomorrow, +3d, 2w"
  (lambda () (todo--ask-at! "Deadline: " 'deadline)))
(define-command "todo-set-project" "Move the task, or the marked tasks, to another project; a new name makes a new project"
  (lambda ()
    (let ((t (todo--at)))
      (if (or t (pair? (todo--marked-tasks)))
          (completing-read "Project: " (todo-projects)
            (lambda (s)
              (todo--with-tasks (string-append "Move to " s ":")
                (lambda (t) (todo-update (plist-get t 'id) (list 'project s)))))
            'default (or (and t (plist-get t 'project)) ""))
          (message "No task at point")))))
(define-command "todo-add-note" "Add a note to the task"
  (lambda () (todo--ask-at! "Note: " 'note)))

(define-command "todo-capture" "File a new task"
  (lambda ()
    (read-string "Task: "
      (lambda (s)
        (let ((id (todo-create s (list 'state "todo" 'group (todo--origin-group todo-user)))))
          (todo--refresh-all!)
          (message (string-append "Filed " id)))))))

;; a chat files its own card: the task is the chat's, in doing, so the
;; board can tell a chat that finished from one that stopped halfway
(define-command "chat-todo" "Turn this chat into a todo: assigned to it, in doing; a blank title takes the chat's title, with its running summary as the notes"
  (lambda ()
    (let* ((chat (current-buffer))
           (who (and (chat-buffer? chat) (chat-stable-id! chat)))
           (held (and who (todo-list (list 'assignee who)))))
      (cond ((not who) (message "Not a chat"))
            ((pair? held) (message (string-append "This chat holds " (plist-get (car held) 'id))))
            (else
             (read-string "Task (blank: from the chat): "
               (lambda (s)
                 (let* ((blank? (todo--blank? s))
                        (title (if blank? (chat-title-of chat) s))
                        (summary (buffer-local chat 'chat-summary))
                        (g (buffer-group chat))
                        (name (and g (group-name g)))
                        (id (todo-create title (append (list 'project (if (member name (todo-projects)) name todo-default-project)
                                                             'state "doing" 'assignee who 'group g)
                                                       (if (and blank? (string? summary) (not (todo--blank? summary)))
                                                           (list 'notes summary)
                                                           '())))))
                   (todo--refresh-all!)
                   (message (string-append "Filed " id ": " title))))
               'initial chat))))))

(define (todo--view-set! buf name)
  (list-tab-set! buf name)
  (list-refresh! buf))

(define (todo--view-step! buf step)
  (list-tab-step! buf (map car *todo-views*) step "open")
  (list-refresh! buf))

;; a tab's count is what the tab would show under the list's group and
;; project filters. Reading the tasks is the slow part, so every tab counts
;; from one read
(define (todo--tab-count all scoped view)
  (let* ((s (cadr view))
         (spec (if (equal? s 'mine) (list 'assignee todo-user) s)))
    (length (filter (lambda (t) (todo--match? t spec all)) scoped))))

;; the views as ui/tabs in the window's header line; left and right step,
;; a click takes one
(define (todo--tab-blocks buf)
  (let* ((all (todo--all))
         (fs (filter (lambda (f) (member (car f) '("group" "project"))) (list-filters buf)))
         (scoped (filter (lambda (t) (null? (remove (lambda (f) (todo--filter buf t f)) fs))) all)))
    (list (component 'ui/tabs
            (list 'class "todo-tabs"
                  'tabs (map (lambda (v)
                               (list (string-append "todo-tab-" (car v))
                                     (string-append (car v) " " (number->string (todo--tab-count all scoped v)))
                                     (equal? (car v) (todo--view buf))))
                             *todo-views*))))))

(add-hook! (list 'block-click 'todo-tabs)
  (lambda (buf id)
    (and (string? id)
         (string-prefix? "todo-tab-" id)
         (buffer-exists? buf)
         (let ((name (substring id 9 (string-length id))))
           (and (assoc name *todo-views*)
                (begin (todo--view-set! buf name) #t))))))

(define-command "todo-next-view" "Show the next status tab: open, inbox, review, doing, waiting, mine, overdue, closed, all"
  (lambda () (todo--view-step! (todo--list-buffer) 1)))

(define-command "todo-prev-view" "Show the previous status tab"
  (lambda () (todo--view-step! (todo--list-buffer) -1)))

(define-command "todo-filter-project" "Show one project's tasks: pick it from the list; all shows every project"
  (lambda ()
    (let ((buf (todo--list-buffer)))
      (completing-read "Project: " (cons "all" (todo-projects))
        (lambda (p)
          (list-facet-set! buf (list-facet buf "project") (if (member p '("" "all")) #f p)))
        'default "all"))))

(define-command "todo-refresh" "Re-read the todo files, and look again for new ones"
  (lambda () (todo--refresh-all!) (todo--rescan!)))

(define-command "todo-next-sort" "Cycle the order: status, urgency, deadline, created"
  (lambda ()
    (let* ((buf (todo--list-buffer))
           (next (list-sort-step! buf *todo-sorts* 1 "status")))
      (list-refresh! buf)
      (message (string-append "Todos by " next)))))

(define-list-mode! "todo-mode"
  (list
    'buffer *todo-buffer*
    'special #f
    ;; moving shows the row's page beside the list once the highlight rests;
    ;; the page's chat-follow? brings its chat
    'preview (lambda (buf t)
                (unless (todo--sep? t)
                  (todo-show-detail! (plist-get t 'id))))
    'debounce #t
    'head-blocks todo--tab-blocks
    'title (lambda (buf) (string-append "Todos   " (todo--view buf) " · by " (todo--sort-by buf)))
    'title-spans (lambda (buf)
                   (let ((rest (string-append (todo--view buf) " · by " (todo--sort-by buf))))
                     (list (list 0 5 "todo-heading") (list 8 (string-byte-length rest) "dim"))))
    'layouts (list (list 'name 'wide
                         'min-cols todo-wide-cols
                         'columns todo--wide-columns
                         'cells todo--cells)
                   (list 'name 'narrow
                         'default #t
                         'columns todo--narrow-columns
                         'cells todo--narrow-cells))
    'key (lambda (buf t) (plist-get t 'id))
    ;; the whole card lights up, not just its title line
    'selection-face "select"
    'selection-trim 1
    'rows todo--rows
    'render (lambda (buf t) (plist-get t 'title))
    'match todo--match
    'filter todo--filter
    'facets *todo-facets*
    'regroup todo--regroup!
    'resort (lambda (buf) (run-command "todo-next-sort"))
    'separator? (lambda (buf t) (todo--sep? t))
    'section? (lambda (buf t) (todo--sep? t))
    ;; a sub-task sits under its task; the title takes the indent
    'parent (lambda (buf t) (and (not (todo--sep? t)) (plist-get t 'parent)))
    'nest-cell 2
    'footer (lambda (buf)
              '(("←→" "status") ("RET" "open") ("TAB" "fold") ("e" "file") ("t" "accept") ("d" "done") ("x" "cancel") ("W" "wait") ("w" "chat")
                ("a" "assign") ("C" "attach chat") ("D" "deadline") ("P" "project") ("!" "priority") ("T" "urgent")
                ("c" "capture") ("/" "filter") ("<" "group") (">" "sort") ("g" "refresh") ("q" "quit")))
    'noun "task"
    ;; the stacked layout has no columns until it draws, so the table's own
    ;; arrow remap misses it at open; the mode states it
    'remap '(("next-line" "list-next") ("previous-line" "list-prev"))
    'keys '(("RET" "todo-show")
            ("TAB" "list-toggle-children")
            ("S-TAB" "list-toggle-all-children")
            ("M-o" "todo-task-chat")
            ("e" "todo-visit")
            ("t" "todo-accept")
            ("d" "todo-mark-done")
            ("x" "todo-mark-cancelled")
            ("W" "todo-mark-waiting")
            ("w" "todo-goto-chat")
            ("s" "todo-mark-doing")
            ("a" "todo-assign")
            ("C" "todo-attach-chat")
            ("D" "todo-set-deadline")
            ("P" "todo-set-project")
            ("N" "todo-add-note")
            ("!" "todo-cycle-priority")
            ("T" "todo-toggle-urgent")
            ("c" "todo-capture")
            ("v" "todo-next-view")
            ("<right>" "todo-next-view")
            ("<left>" "todo-prev-view")
            ("F" "todo-filter-project")
            (">" "todo-next-sort")
            ("g" "todo-refresh")
            ("q" "quit-window"))
    'doc "The shared todo list from todo-directories, most urgent first: review, then doing, todo, inbox and waiting. `t` accepts a task (triage it, or approve it from review), `d` closes it, `x` cancels, `W` parks it, `w` goes to the chat it is assigned to, or asks which when several are attached, `s` starts it. `a` hands it to a new chat in a group, `C` attaches another open chat to it, `D` sets a deadline, `P` moves it to a project, `N` adds a note, `!` cycles the priority, `T` marks it time-sensitive (urgent) or not. With tasks marked (`SPC`, or `*` for every task the filter shows), `t`, `d`, `x`, `W`, `s`, `a`, `D`, `P`, `N`, `!` and `T` act on the marked tasks after asking. `c` files a new task. The status tabs, each with its count, head the list: open, inbox, review, doing, waiting, mine, overdue, closed, all; left and right (or `v`) step them, and a click takes one. `>` cycles the order: status, urgency (urgent first), deadline, created (newest first). `<` cycles the sections: none, group, project, status. It opens on the tasks of the group you are in. `/` filters with tabs, Group, Project and Status, each led by All; left and right change the tab. Words that match no choice filter the text: p:project, s:state, @assignee, #tag, !priority, or any text; `\\` drops the filter. A sub-task sits under its task, indented; `TAB` folds the sub-tasks under a task, and `S-TAB` folds them all or opens them all. `RET` shows the task as its own page, where `w` reaches the chat working it; `e` opens the task's file."))

;; the list is an index and a task's page its detail: RET opens it beside
;; the list, and the detail steps to the next and previous task in place
(when (boundp 'index-declare!)
  (index-declare! "todo-mode" 'next "list-next" 'prev "list-prev" 'open "todo-show"))

(define-command "todo" "Show the todo list of the group you are in"
  (lambda ()
    ;; a normal buffer of the group, so showing it keeps the frame in the
    ;; group; each group reuses its own list, and a new one opens on it
    (let* ((group (group-here))
           (fresh (not (find (lambda (b) (equal? (buffer-group b) group)) (todo--buffers))))
           (buf (todo--group-buffer "todo-mode" *todo-buffer* group)))
      ;; the list opens in the window you are in, as an app's does
      (if (boundp 'app-open!) (app-open! buf) (switch-to-buffer! buf))
      ;; it opens on the group you are in; / picks another one, or All
      (when fresh
        (list-facet-set! buf (list-facet buf "group") group))
      buf)))

;;; --- the prompt --------------------------------------------------------------
;;; Every chat learns the list. A project or group that wants it out says
;;; (prompt-section-off! (current-buffer) "todo") in its config.

(domain! 'chat)
(effects! '(write))

(define todo-prompt
  "## Shared todo list

The user and every agent share one todo list. Each project keeps its tasks in a PROJECT/todos.md that `todo-directories` finds. Use the todo calls; do not edit those files.

- Read: `(todo-list [SPEC])` gives open tasks, most urgent first. SPEC is a plist: state, project, assignee (\"none\" is unassigned), tag, text, overdue, ready. `(todo-next WHO)`, `(todo-get ID)` and `(todo-projects)` answer the rest.
- File: `(todo-create TITLE PROPS)` gives the new id. PROPS must hold 'group: \"put a todo in X\" means group X, by name or id, not a project and not your own chat's group. Without it the call errors and lists the groups; pick one and call again. A task you find goes in as inbox, for the user to triage.
- Kick off: when the user asks for a todo, file it and start an agent on it in the same turn with `(todo-assign-chat! ID GROUP WHO)`, GROUP being the todo's group. It starts the chat on the group's own backend and sends it the brief. Do not stop at filing, and do not ask whether to start it.
- Work: `(todo-claim ID WHO)`, then `(todo-done ID RESULT WHO)`, `(todo-wait ID REASON WHO)` or `(todo-review ID SUMMARY WHO)`. `(todo-log ID TEXT WHO)` records progress.
- Waiting on someone: after `todo-wait`, call `(agent-listen! '(topic \"whatsapp:PHONE\" kind received task ID) NOTE)`. The event comes to you as a message; decide whether it answers, then carry on or listen again. `mail:ACCOUNT` topics need `match` with the sender.
- WHO, and 'by in PROPS, is `agent:` and your agent id from `(chat-context)`.
- A task that needs the user's OK, such as a draft before it goes out, goes to review. Do not continue it until the user approves.")

(define (todo--chat-mode-hook!)
  (prompt-part-set! (current-buffer) "todo" todo-prompt))

(add-hook! 'chat-mode-hook 'todo--chat-mode-hook!)

;; a chat restored or opened before this package loaded missed the hook
(for-each (lambda (b)
            (when (chat-buffer? b)
              (prompt-part-set! b "todo" todo-prompt)))
          (buffer-list))

;; a task cannot start while the boot loads this file, and a failed form
;; drops the whole package; so the first scan waits for the boot to end
(debounce! 'todo-boot-rescan 0 (lambda (_) (todo--rescan!)) #f)
