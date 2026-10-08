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
(define *todo-fields* '(id state assignee priority source parent depends created by))
;; what todo-update may change
(define *todo-settable*
  '(title state project assignee priority deadline scheduled tags source parent depends notes))

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
        ((todo--blank? v) '())
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

(define (todo--resolve)
  (fold (lambda (acc f) (if (member f acc) acc (append acc (list f))))
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
        (when (buffer-exists? *todo-buffer*) (list-refresh! *todo-buffer*))))))

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

(define (todo--all)
  (fold (lambda (acc f) (append acc (todo--parse f (todo--text f)))) '() (todo--files)))

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

(define (todo-create title &optional props)
  "(todo-create TITLE [PROPS]) — file a task; return its id. PROPS: project, state (default inbox), assignee, priority, deadline, scheduled, tags, source, parent, depends, notes, by. A source already filed is not filed twice: that task's id comes back."
  (let* ((props (or props '()))
         (src (plist-get props 'source))
         (dup (and (not (todo--blank? src))
                   (todo--first (lambda (t) (equal? (plist-get t 'source) src)) (todo--all)))))
    (if dup
        (plist-get dup 'id)
        (let* ((who (or (plist-get props 'by) todo-user))
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
        ((equal? k 'depends) (todo--ids v))
        ((equal? k 'priority) (todo--priority v))
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

(define (todo-update id props)
  "(todo-update ID PROPS) — change a task; return it. PROPS: any of title, state, project, assignee, priority, deadline, scheduled, tags, source, parent, depends, notes (#f or blank clears one), plus note (text added to the notes), log (a line for the log) and by (who). Each change is logged."
  (let* ((t (todo--must id))
         (who (or (plist-get props 'by) todo-user)))
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
                 (if (equal? v (plist-get new k))
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
(public! 'todo-create "(todo-create TITLE [PROPS]) — file a task; answers its id. PROPS may hold 'by, the name the change is logged under")
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

(define *todo-views*
  (list (list "open" '())
        (list "inbox" '(state "inbox"))
        (list "review" '(state "review"))
        (list "working" '(state "doing"))
        (list "mine" 'mine)
        (list "overdue" '(overdue #t))
        (list "closed" '(state ("done" "cancelled")))))

(define (todo--view buf) (or (buffer-local buf 'todo-view) "open"))

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

(define *todo-sorts* '("urgency" "deadline" "created"))

(define (todo--sort-by buf) (or (buffer-local buf 'todo-sort) "urgency"))

(define (todo--resort ts by)
  "deadline: soonest first, undated last. created: newest first. urgency: todo-list's own order."
  (cond ((equal? by "deadline")
         (map cadr (sort (map (lambda (t) (list (list (todo--date-num (plist-get t 'deadline))
                                                      (or (plist-get t 'created) ""))
                                                t))
                              ts))))
        ((equal? by "created")
         (reverse (map cadr (sort (map (lambda (t) (list (or (plist-get t 'created) "") t)) ts)))))
        (else ts)))

(define (todo--rows buf) (list-keep buf (todo--resort (todo-list (todo--view-spec buf)) (todo--sort-by buf))))

(define (todo--due t)
  (let ((d (plist-get t 'deadline)))
    (cond ((not d) "") ((todo--overdue? t) (string-append d " !")) (else d))))

;; the state, priority, project, dates and tags under the title
(define (todo--meta t)
  (string-join
    (filter (lambda (s) (not (equal? s "")))
            (list (plist-get t 'state)
                  (let ((p (plist-get t 'priority))) (if p (string-append "#" p) ""))
                  (plist-get t 'project)
                  (if (plist-get t 'deadline) (string-append "due " (todo--due t)) "")
                  (if (plist-get t 'scheduled) (string-append "scheduled " (plist-get t 'scheduled)) "")
                  (let ((tags (plist-get t 'tags)))
                    (if (pair? tags) (string-append ":" (string-join tags ":") ":") ""))))
    "  ·  "))

;; each state wears a tinted pill; the dot before the title shares its colour
(defface! 'todo-title 'weight "600")
(defface! 'todo-project 'inherit 'accent)
(defface! 'todo-tags 'fg "#8a857a")
(defface! 'todo-date 'fg "#26356b")
(defface! 'todo-overdue 'fg "#a83a2b" 'weight "700")
(defface! 'todo-state-review 'fg "#a03020" 'bg "rgba(160, 48, 32, 0.12)" 'weight "600")
(defface! 'todo-state-doing 'fg "#7a5a1a" 'bg "rgba(194, 138, 44, 0.16)" 'weight "600")
(defface! 'todo-state-todo 'fg "#26356b" 'bg "rgba(38, 53, 107, 0.10)" 'weight "600")
(defface! 'todo-state-inbox 'fg "#676257" 'bg "rgba(138, 133, 122, 0.14)" 'weight "600")
(defface! 'todo-state-waiting 'fg "#5a3a7a" 'bg "rgba(90, 58, 122, 0.12)" 'weight "600")
(defface! 'todo-state-done 'fg "#2e6b45" 'bg "rgba(46, 107, 69, 0.12)" 'weight "600")
(defface! 'todo-state-cancelled 'fg "#8a857a" 'decoration "line-through")

(define (todo--state-face t)
  (let ((f (string-append "todo-state-" (or (plist-get t 'state) "inbox"))))
    (if (member f (face-list)) f "todo-state-inbox")))

(define (todo--pill t)
  (list (string-append " " (or (plist-get t 'state) "") " ") (todo--state-face t)))

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
  (let ((tags (plist-get t 'tags)))
    (if (pair? tags) (string-join (map (lambda (g) (string-append "#" g)) tags) " ") "")))

;; a window this wide shows a task on one line; a narrower one gives the
;; title its own line, so the title is not cut
(define todo-wide-cols 150)

(define (todo--wide-columns buf)
  (list (list "STATE" 11)
        (list "P" 1)
        (list "TODO" #f 'left 'end)
        (list "PROJECT" 12)
        (list "WHO" 16)
        (list "DUE" 12)))

(define (todo--cells buf t)
  (list (todo--pill t)
        (list (or (plist-get t 'priority) "") "org-priority")
        (list (plist-get t 'title) "todo-title")
        (list (plist-get t 'project) "todo-project")
        (list (todo--who-status t) "org-meta")
        (todo--when t)))

(define (todo--row-columns buf)
  (list (list (list "" 2) (list "TODO" #f 'left 'end))
        (list (list "" 2) (list "STATE" 10) (list "PROJECT" 13) (list "WHEN" 11)
              (list "TAGS" #f 'left 'end) (list "WHO" 26 'right))
        (list (list "" #f 'left 'end))))

(define (todo--row-cells buf t)
  ;; a card: a state dot and the title, then a state pill, the project,
  ;; the date and the tags, with a blank line between cards
  (list (list (list "●" (todo--state-face t)) (list (plist-get t 'title) "todo-title"))
        (list "" (todo--pill t) (list (plist-get t 'project) "todo-project")
              (todo--when t) (list (todo--tag-text t) "todo-tags")
              (list (todo--who-status t) "org-meta"))
        (list "")))

(define (todo--at) (list-current *todo-buffer*))

(define (todo--keep-place! f)
  "run F, which may change the task at point, and redraw. A task whose state changes moves in the urgency order; point stays where the reader was, on the task that followed it, so working down the inbox does not lose the place"
  (let* ((buf *todo-buffer*)
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

(define (todo--set-at! k v)
  (todo--with-row (lambda (t) (todo-update (plist-get t 'id) (list k v)))))

(define (todo--ask-at! prompt k)
  (let ((t (todo--at)))
    (if t
        (read-string prompt
          (lambda (s)
            (todo-update (plist-get t 'id) (list k s))
            (list-refresh! *todo-buffer*)))
        (message "No task at point"))))

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

(define-command "todo-cycle-priority" "Cycle the task's priority: A, B, C, none"
  (lambda ()
    (todo--with-row
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
     "- (todo-done \"" id "\" RESULT \"" chat "\") when it is finished\n")))

(define (todo-assign-chat! id group &optional who)
  "(todo-assign-chat! ID GROUP [WHO]) — start a new chat in GROUP, make it the task's assignee and send it the brief; return the chat"
  (let* ((t (todo--must id))
         (g (or (group-resolve-id group) (group-ensure-record! group)))
         (chat (group-chat-new-name g)))
    (buffer-create chat)
    (group-chat-init! chat g)
    (chat-set-group! chat g)
    (when (boundp 'llm-default-bundle-apply!) (llm-default-bundle-apply! chat))
    (when (boundp 'workspace-chat-inherit!) (workspace-chat-inherit! chat (group-name g)))
    (todo-update id (list 'assignee (chat-stable-id! chat)
                          'state (if (member (plist-get t 'state) '("inbox" "todo")) "doing" (plist-get t 'state))
                          'log (string-append "assigned to a chat in " (group-name g))
                          'by (or who todo-user)))
    (agent-continue! chat (todo--brief (todo-get id) (chat-stable-id! chat)))
    chat))

;; the assignee of a chat-held task is the chat's stable id, since the
;; chat renames itself after its first answer
(define (todo--chat-of t)
  (let ((a (plist-get t 'assignee)))
    (and (string? a) (string-prefix? "chat:" a)
         (todo--first (lambda (b) (equal? (buffer-local b 'chat-id) a)) (buffer-list)))))

(define (todo--who t) (or (todo--chat-of t) (plist-get t 'assignee) ""))

;; a card says how its chat is doing. The event log's chat-status view
;; knows it; the todo file does not hold it.
(define (todo--status t)
  (let* ((a (plist-get t 'assignee))
         (row (and (string? a) (event-view-get 'chat-status a))))
    (if (not row)
        ""
        (let ((status (plist-get row 'status))
              (stop (plist-get row 'stop-reason)))
          (string-append (if status (chats-state-label status) "turn ended")
                         (if (and stop (not (agent-turn-end-normal? stop)))
                             (string-append " (" stop ")")
                             "")
                         " " (format-time (plist-get row 'at) "%H:%M"))))))

(define (todo--who-status t)
  (let ((who (todo--who t)) (status (todo--status t)))
    (cond ((equal? status "") who)
          ((equal? who "") status)
          (else (string-append who "  ·  " status)))))

(define-command "todo-goto-chat" "Go to the chat the task is assigned to"
  (lambda ()
    (let* ((t (todo--at)) (chat (and t (todo--chat-of t))))
      (cond ((not t) (message "No task at point"))
            (chat (switch-to-buffer-in-group! chat))
            (else (message "The task is not with a live chat"))))))

(define (todo-spawn-chat! group title)
  "(todo-spawn-chat! GROUP TITLE) — file TITLE as a task and hand it to a new chat in GROUP. Nothing is shown and the focus stays: the task is the marker that comes back to the user in review. Return (ID CHAT)"
  (let* ((g (or (group-resolve-id group) (group-ensure-record! group)))
         (name (group-name g))
         (id (todo-create title (list 'project (if (member name (todo-projects)) name todo-default-project)
                                      'state "todo")))
         (first? (not (group-primary-chat g)))
         (chat (todo-assign-chat! id g)))
    ;; a group made here has no chat yet: this one becomes its chat pane
    (when first? (group-record-update! g 'primary-chat-id (chat-stable-id! chat)))
    (list id chat)))

(public! 'todo-spawn-chat! "(todo-spawn-chat! GROUP TITLE) — file a task and hand it to a new chat in GROUP without showing it; answers (ID CHAT)")

(define-command "todo-assign" "Hand the task to a new chat in its project's group and show it in the other window; C-u asks for the group"
  (lambda ()
    (let ((t (todo--at))
          (ask? (and (current-prefix-arg) #t)))
      (define (assign! g)
        (let ((chat #f))
          (todo--keep-place! (lambda () (set! chat (todo-assign-chat! (plist-get t 'id) g))))
          (display-buffer-other-window! chat)
          (message (string-append "Assigned to " chat))))
      (cond ((not t) (message "No task at point"))
            ((or ask? (not (plist-get t 'project)))
             (group-read-or-create! "Assign to a new chat in group: "
               (lambda (g) (assign! g))))
            (else (assign! (plist-get t 'project)))))))
;; a card follows its chat: an event on a chat topic redraws the list
;; when a window shows it, and marks it stale when none does
(define (todo--on-chat-event e)
  (when (buffer-known? *todo-buffer*)
    (if (window-showing *todo-buffer*)
        (debounce! 'todo-cards 250 (lambda (_) (list-redraw! *todo-buffer*)) #f)
        (buffer-set-local! *todo-buffer* 'todo-stale #t))))

(define (todo--redraw-if-stale)
  (when (and (buffer-known? *todo-buffer*)
             (buffer-local *todo-buffer* 'todo-stale)
             (window-showing *todo-buffer*))
    (buffer-set-local! *todo-buffer* 'todo-stale #f)
    (list-redraw! *todo-buffer*)))

(event-subscribe! "todo-cards" "chat:*" 'todo--on-chat-event)
(add-hook! 'window-configuration-change-hook 'todo--redraw-if-stale)

(define-command "todo-set-deadline" "Set the task's deadline: YYYY-MM-DD, today, tomorrow, +3d, 2w"
  (lambda () (todo--ask-at! "Deadline: " 'deadline)))
(define-command "todo-set-project" "Move the task to another project; a new name makes a new project"
  (lambda ()
    (let ((t (todo--at)))
      (if t
          (completing-read "Project: " (todo-projects)
            (lambda (s)
              (todo-update (plist-get t 'id) (list 'project s))
              (list-refresh! *todo-buffer*))
            'default (or (plist-get t 'project) ""))
          (message "No task at point")))))
(define-command "todo-add-note" "Add a note to the task"
  (lambda () (todo--ask-at! "Note: " 'note)))

(define-command "todo-capture" "File a new task"
  (lambda ()
    (read-string "Task: "
      (lambda (s)
        (let ((id (todo-create s (list 'state "todo"))))
          (when (buffer-exists? *todo-buffer*) (list-refresh! *todo-buffer*))
          (message (string-append "Filed " id)))))))

(define-command "todo-next-view" "Cycle the view: open, inbox, review, working, mine, overdue, closed"
  (lambda ()
    (let* ((names (map car *todo-views*))
           (i (todo--rank (todo--view *todo-buffer*) names))
           (next (nth (modulo (+ i 1) (length names)) names)))
      (buffer-set-local! *todo-buffer* 'todo-view next)
      (list-refresh! *todo-buffer*)
      (message (string-append "Todos: " next)))))

(define-command "todo-filter-project" "Show one project's tasks: pick it from the list; all shows every project"
  (lambda ()
    (let* ((buf *todo-buffer*)
           (rest (filter (lambda (w) (not (or (equal? w "") (string-prefix? "p:" w))))
                         (string-split (list-query buf) " "))))
      (completing-read "Project: " (cons "all" (todo-projects))
        (lambda (p)
          (list-set-query! buf (string-join (if (member p '("" "all")) rest (append rest (list (string-append "p:" p)))) " "))
          (list-refresh! buf))
        'default "all"))))

(define-command "todo-refresh" "Re-read the todo files, and look again for new ones"
  (lambda () (list-refresh! *todo-buffer*) (todo--rescan!)))

(define-command "todo-next-sort" "Cycle the order: urgency, deadline, created"
  (lambda ()
    (let* ((i (todo--rank (todo--sort-by *todo-buffer*) *todo-sorts*))
           (next (nth (modulo (+ i 1) (length *todo-sorts*)) *todo-sorts*)))
      (buffer-set-local! *todo-buffer* 'todo-sort next)
      (list-refresh! *todo-buffer*)
      (message (string-append "Todos by " next)))))

(define-list-mode! "todo-mode"
  (list
    'buffer *todo-buffer*
    'title (lambda (buf) (string-append "Todos · " (todo--view buf) " · by " (todo--sort-by buf)))
    'layouts (list (list 'name 'wide
                         'min-cols todo-wide-cols
                         'columns todo--wide-columns
                         'cells todo--cells)
                   (list 'name 'stacked
                         'default #t
                         'row-columns todo--row-columns
                         'row-cells todo--row-cells))
    'key (lambda (buf t) (plist-get t 'id))
    ;; the whole card lights up, not just its title line
    'selection-face "select"
    'selection-trim 1
    'rows todo--rows
    'render (lambda (buf t) (plist-get t 'title))
    'match todo--match
    'footer (lambda (buf)
              '(("RET" "open") ("t" "accept") ("d" "done") ("x" "cancel") ("W" "wait") ("w" "chat")
                ("a" "assign") ("D" "deadline") ("P" "project") ("!" "priority")
                ("c" "capture") ("v" "view") ("F" "project") (">" "sort") ("g" "refresh") ("q" "quit")))
    'noun "task"
    'keys '(("RET" "todo-visit")
            ("t" "todo-accept")
            ("d" "todo-mark-done")
            ("x" "todo-mark-cancelled")
            ("W" "todo-mark-waiting")
            ("w" "todo-goto-chat")
            ("s" "todo-mark-doing")
            ("a" "todo-assign")
            ("D" "todo-set-deadline")
            ("P" "todo-set-project")
            ("N" "todo-add-note")
            ("!" "todo-cycle-priority")
            ("c" "todo-capture")
            ("v" "todo-next-view")
            ("F" "todo-filter-project")
            (">" "todo-next-sort")
            ("g" "todo-refresh")
            ("q" "quit-window"))
    'doc "The shared todo list from todo-directories, most urgent first: review, then doing, todo, inbox and waiting. `t` accepts a task (triage it, or approve it from review), `d` closes it, `x` cancels, `W` parks it, `w` goes to the chat it is assigned to, `s` starts it. `a` hands it to a new chat in a group, `D` sets a deadline, `P` moves it to a project, `N` adds a note, `!` cycles the priority. `c` files a new task. `v` cycles the view: open, inbox, review, working, mine, overdue, closed. `>` cycles the order: urgency, deadline, created (newest first). `F` shows one project, picked from a list. `/` filters by words: p:project, s:state, @assignee, #tag, !priority, or any text; `\\` drops the filter. `RET` opens the task's file."))

(define-command "todo" "Show the shared todo list"
  (lambda ()
    (buffer-create *todo-buffer*)
    (switch-to-buffer! *todo-buffer*)
    (set-mode! "todo-mode")
    *todo-buffer*))

;;; --- the prompt --------------------------------------------------------------
;;; Every chat learns the list. A project or group that wants it out says
;;; (prompt-section-off! (current-buffer) "todo") in its config.

(domain! 'chat)
(effects! '(write))

(define todo-prompt
  "## Shared todo list

The user and every agent share one todo list. Each project keeps its tasks in a PROJECT/todos.md that `todo-directories` finds. Use the todo calls; do not edit those files.

- Read: `(todo-list [SPEC])` gives open tasks, most urgent first. SPEC is a plist: state, project, assignee (\"none\" is unassigned), tag, text, overdue, ready. `(todo-next WHO)`, `(todo-get ID)` and `(todo-projects)` answer the rest.
- File: `(todo-create TITLE PROPS)` gives the new id. A task you find goes in as inbox, for the user to triage.
- Work: `(todo-claim ID WHO)`, then `(todo-done ID RESULT WHO)`, `(todo-wait ID REASON WHO)` or `(todo-review ID SUMMARY WHO)`. `(todo-log ID TEXT WHO)` records progress.
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
