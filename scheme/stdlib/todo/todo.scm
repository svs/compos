;;; todo.scm --- the shared todo list every app and agent coordinates through.
;;;
;;; A task is a level-2 morg heading in its group's todos.md,
;;; groups/<id>/todos.md, found by todo-directories; its #+project: line
;;; names its project. An older hiring/todos.md holds the tasks of project
;;; "hiring" until todo-move-to-groups! moves them.
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

;; the chat hook and the boot sweep below set a prompt part
(require 'prompts)
(require 'app-watch)
(require 'tab-bars)
(require 'apps)
(require 'events)
(require 'transient)
(require 'tabulated-list)

(domain! 'writing)
(effects! '(read))

;; The default follows the home of this daemon. A daemon with its own
;; COMPOS_HOME then does not read or write the todo files of another daemon.
(define (todo--home-directories)
  (list (string-append (compos-home) "/**/todos.md")))

(defcustom 'todo-directories (todo--home-directories)
  "Where the todo files live: paths and patterns, where `*` matches within one name and `**` any depth of folders. The default is every todos.md under the compos home of this daemon, (compos-home). A group's tasks are in its folder, groups/<id>/todos.md, and each one names its project. An older todos.md elsewhere is the project its folder names; any other file, the project its own name gives.")

(defcustom 'todo-skip-directories
  '("node_modules" "_build" "deps" "target" "venv" "dead" "worktree-daemons" "chrome-profile" "grammars")
  "Folders a `**` in todo-directories never goes into, by name: build output, archives and the editor's own data, which hold many files and no todos. Folders whose name starts with a dot are skipped too.")

(defcustom 'todo-user "svs"
  "The name a change is logged under when the caller names nobody.")

(defcustom 'todo-turn-log #t
  "After each judged turn, add the turn's verdict (working, needs-you, blocked, success, idle) and its reason to the log of each open task the chat is assigned.")

(defcustom 'todo-default-project "general"
  "The project of a task created without one.")

(define *todo-states* '("inbox" "todo" "doing" "waiting" "review" "done" "cancelled"))

;; The state machine: each state and the states a task may move to from it.
;; done and cancelled are closed; the one way out is back to todo, a reopen.
(define *todo-moves*
  '(("inbox" "todo" "doing" "waiting" "done" "cancelled")
    ("todo" "inbox" "doing" "waiting" "review" "done" "cancelled")
    ("doing" "inbox" "todo" "waiting" "review" "done" "cancelled")
    ("waiting" "inbox" "todo" "doing" "review" "done" "cancelled")
    ("review" "inbox" "todo" "doing" "waiting" "done" "cancelled")
    ("done" "todo")
    ("cancelled" "todo")))
(define *todo-closed* '("done" "cancelled"))
;; the #+ lines, in the order they are written
(define *todo-fields* '(id state assignee chats priority urgent goal source parent depends created by group project))
;; what todo-update may change
(define *todo-settable*
  '(title state project assignee chats priority urgent deadline scheduled tags source parent depends goal notes status group))

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

(effects! '(pure))

(define (todo-moves state)
  "(todo-moves STATE) — the states a task in STATE may move to"
  (let ((row (assoc state *todo-moves*))) (if row (cdr row) '())))

(define (todo-can-move? from to)
  "(todo-can-move? FROM TO) — whether a task may go from state FROM to state TO; staying put is always fine"
  (or (equal? from to) (and (member to (todo-moves from)) #t)))

(public! 'todo-moves "(todo-moves STATE) — the states a task in STATE may move to")
(public! 'todo-of-source "(todo-of-source KEY) — the task filed from the source KEY, open or closed, or #f")
(public! 'todo-source-returned! "(todo-source-returned! ID REASON [WHO]) — the task's source came back: open it again and wake its chat")
(public! 'todo-source-page-register! "(todo-source-page-register! PREFIX FN) — a source key starting PREFIX shows on the page (FN KEY)")
(public! 'todo-source-opener-register! "(todo-source-opener-register! PREFIX FN) — a source key starting PREFIX opens with (FN KEY)")
(public! 'todo-source-open! "(todo-source-open! KEY) — open the source KEY beside the task; #f when nothing opens it")
(public! 'todo-source-rounds "(todo-source-rounds TASK) — how many times the task's source came back")
(public! 'todo-can-move? "(todo-can-move? FROM TO) — whether a task may go from state FROM to state TO; staying put is always fine")

(define (todo--check-move! t to)
  (let ((from (plist-get t 'state)))
    (unless (todo-can-move? from to)
      (todo--fail (plist-get t 'id) " is " from " and cannot go to " to
                  (let ((ok (todo-moves from)))
                    (if (pair? ok) (string-append "; it can go to " (string-join ok ", ")) ""))
                  (if (member from *todo-closed*) " (todo-reopen opens it again)" "")))))

(define (todo--has-key? props k)
  (and (pair? props) (or (equal? (car props) k) (and (pair? (cdr props)) (todo--has-key? (cddr props) k)))))

(effects! '(read))

(define (todo--new-id)
  (string-append "t-" (format-time (current-time) "%y%m%d-%H%M%S")
                 "-" (number->string (+ 100 (random 900)))))

;; A log entry is one line of the file: a line break in TEXT would end the
;; entry and put the rest in the task's body.
(define (todo--log-line who text)
  (string-append (todo--now) " " who " " (re-replace-all "\\s*\\n\\s*" (string-trim text) " ")))

;;; --- files -------------------------------------------------------------------

;; the files todo-directories names. Expanding `**` reads every folder
;; under it. file-glob does that in one call, a few milliseconds on a home
;; of some hundred folders, so a caller that finds no list yet can make
;; one in place. A task still renews the list: at load, on `g`, and when a
;; new project's file is written.
(define (todo--glob pattern)
  (file-glob pattern todo-skip-directories))

;; A worktree daemon keeps its own copy of ~/.compos under worktree-daemons/;
;; its todos.md files are stale copies of the user's, so `**` must not reach them.
(define (todo--resolve)
  (reverse
    (fold (lambda (acc f) (if (or (member f acc) (string-contains? f "/worktree-daemons/")) acc (cons f acc)))
          '() (apply append (map todo--glob todo-directories)))))

(define *todo-files* #f)

(define (todo-ready?)
  "(todo-ready?) — #t when the todo files are found, so a list costs no walk of the folders"
  (and *todo-files* #t))

(define (todo--files)
  (unless *todo-files* (set! *todo-files* (todo--resolve)))
  (filter file-exists? *todo-files*))

;; The task parses each file too. The first list after a boot then finds
;; the parse made; a parse that fails here fails again where it is read.
(define (todo--resolve-and-parse)
  (let ((files (todo--resolve)))
    (ignore-errors (lambda () (for-each todo--parsed (filter file-exists? files))))
    files))

;; todo-files-hook: (FN) runs when the file list is new. A page that
;; shows a count of tasks and drew before the list was there draws again.
(define (todo--rescan!)
  (task-run! todo--resolve-and-parse
    (lambda (ok? files)
      (when ok?
        (set! *todo-files* files)
        (todo--agenda-sync!)
        (todo--refresh-all!)
        (run-hooks 'todo-files-hook)))))

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

;; A group keeps its tasks in its own folder, groups/<id>/todos.md, so the
;; group carries them: group-export copies the folder. There the project is
;; the task's #+project: line, not the folder's name.
(define (todo--group-path? path)
  (let ((parts (string-split path "/")))
    (and (> (length parts) 2)
         (equal? (list-ref parts (- (length parts) 1)) "todos.md")
         (equal? (list-ref parts (- (length parts) 3)) "groups"))))

(define (todo--path-project path)
  (if (todo--group-path? path) todo-default-project (todo--file-project path)))

(define (todo--group-file g)
  ;; a group that is gone keeps a folder named for its id, as a live one has
  (string-append (compos-home) "/groups/" (group-home-slug (or (group-resolve-id g) g)) "/todos.md"))

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
        ;; the status takes one #+status: line per line of its text
        ((equal? k "status")
         (plist-put t 'status (let ((s (plist-get t 'status))) (if (todo--blank? s) v (string-append s "\n" v)))))
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
                     'project (todo--path-project path) 'file path
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

;; each file's sections as (TEXT TASK), in file order. A section whose text
;; has not changed keeps its task and only moves, so an edit to one task
;; parses that task alone. Most sections stay where they were, so the walk
;; tries the next old one before it searches the rest.
(define *todo-section-cache* '())

(define (todo--moved t line pos)
  (let ((d (- line (plist-get t 'from))))
    (plist-put (plist-put (plist-put t 'from line) 'to (+ (plist-get t 'to) d)) 'pos pos)))

(define (todo--section-tail sec old)
  (cond ((null? old) '())
        ((equal? (car (car old)) sec) old)
        (else (todo--section-tail sec (cdr old)))))

(define (todo--section-spans text)
  "(\"task\" START END) for each ## section of TEXT, as the markdown grammar
   gives them: from its heading to the next # or ## heading, or the end. A
   heading inside a fenced block is text. Two regex passes; the grammar took
   0.3 s on a 1 MB file, on the lane that reads the keys."
  (let* ((fences (map car (re-find* "^[ \t]{0,3}(```|~~~)" text "m")))
         (inside? (lambda (pos) (= 1 (remainder (length (filter (lambda (f) (< f pos)) fences)) 2))))
         (heads (filter (lambda (h) (not (inside? (car h)))) (re-find* "^#{1,2}[ \t]" text "m")))
         (size (string-byte-length text)))
    (let loop ((hs heads) (acc '()))
      (if (null? hs)
          (reverse acc)
          (let* ((h (car hs)) (end (if (pair? (cdr hs)) (car (cadr hs)) size)))
            (loop (cdr hs) (if (= (- (cadr h) (car h)) 3) (cons (list "task" (car h) end) acc) acc)))))))

(define (todo--parse path text)
  (let loop ((caps (todo--section-spans text))
             (line 0) (at 0)
             (old (let ((hit (assoc path *todo-section-cache*))) (if hit (cadr hit) '())))
             (secs '()))
    (if (null? caps)
        (let ((secs (reverse secs)))
          (set! *todo-section-cache*
                (cons (list path secs)
                      (alist-delete *todo-section-cache* path)))
          (filter (lambda (t) (and t (plist-get t 'id))) (map cadr secs)))
        (let* ((s (cadr (car caps)))
               (line (+ line (- (length (string-split (substring-bytes text at s) "\n")) 1)))
               (sec (substring-bytes text s (caddr (car caps))))
               (rest (todo--section-tail sec old))
               (t (if (pair? rest)
                      (let ((t (cadr (car rest)))) (and t (todo--moved t line s)))
                      (let* ((ls (split-lines sec))
                             (head (and (pair? ls) (todo--heading (car ls)))))
                        (and head (todo--task path (list line s head (cdr ls))))))))
          (loop (cdr caps) line s (if (pair? rest) (cdr rest) old) (cons (list sec t) secs))))))

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
                      (alist-delete *todo-parse-cache* f)))
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
        (if (todo--blank? (plist-get t 'status)) '()
            (map (lambda (l) (string-append "#+status: " l))
                 (filter (lambda (l) (not (todo--blank? l))) (string-split (plist-get t 'status) "\n"))))
        (if (todo--blank? notes) '() (list "" notes))
        (if (pair? logs) (cons "" (map (lambda (l) (string-append "#+log: " l)) logs)) '()))
      "\n")))

;;; --- write -------------------------------------------------------------------

(effects! '(write))

;; A write to a todo file redraws every list and task page that shows it, so a
;; task an agent moves moves on screen too. A hidden one waits for its window.
;; The redraw waits for this many ms of quiet: a list of a few hundred tasks
;; takes seconds to draw on the UI lane, and agents write in bursts, so a
;; short wait redrew it once per write and froze the keys (vidura, 2026-11-27).
(define todo-redraw-quiet-ms 1500)

(define (todo--detail-buffers)
  (filter (lambda (b) (equal? (buffer-local-value 'mode-name b) "todo-detail-mode")) (buffer-list)))

(define (todo--changed!)
  (debounce! 'todo-changed todo-redraw-quiet-ms
    (lambda (_)
      (for-each (lambda (b) (if (window-showing b) (list-refresh! b) (buffer-mark-dirty! b 'todo-list)))
                (filter app-watching? (todo--buffers)))
      (for-each (lambda (b) (if (window-showing b) (todo--detail-render! b) (buffer-mark-dirty! b 'todo-detail)))
                (filter app-watching? (todo--detail-buffers))))
    #f))

;; todo redraws on its own writes, so w only turns that on and off
(app-watch-define! "todo-mode")
(app-watch-define! "todo-detail-mode")

;; the user saved a todo file by hand, or another program changed one on disk
(define (todo--after-save!)
  (when (member (buffer-path (current-buffer)) *todo-files*) (todo--changed!)))

(define *todo-mtimes* '())
(define (todo--fs-change root)
  (let ((now (map (lambda (p) (cons p (file-mtime p))) *todo-files*)))
    (unless (equal? now *todo-mtimes*)
      (set! *todo-mtimes* now)
      (todo--changed!))))

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
          (unless (string-prefix? "edited" r) (todo--fail r))
          (unless dirty (todo--save! path)))
        (write-file! path (string-join (append (list-head ls from)
                                               (if new (list new) '())
                                               (list-tail ls to))
                                       "\n"))))
  (todo--changed!))

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
           (write-file! path (string-append "# " (if (todo--group-path? path) "todos" (todo--file-project path)) "\n\n" text "\n"))
           (set! *todo-files* (append (todo--files) (list path)))
           (todo--agenda-sync!))))
  (todo--changed!))

;; the agenda reads every project's todos.md; a new project joins it here
(define (todo--agenda-sync!)
  ;; the agenda is a package (compos-agenda); without it there is no list to keep
  (if (not (boundp 'morg-agenda-files))
      '()
      (let* ((mine (map abbreviate-file-name (todo--files)))
             (others (filter (lambda (f) (let ((p (expand-path f)))
                                           (not (or (member p (todo--files))
                                                    (and (string-suffix? "todos.md" p) (not (file-exists? p)))))))
                             morg-agenda-files))
             (want (append others mine)))
        (unless (equal? want morg-agenda-files)
          (customize-save! 'morg-agenda-files want))
        want)))

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
(define (todo--sort-key t)
  "T's place in the status order: state, then priority, deadline, creation."
  (list (todo--rank (plist-get t 'state) '("review" "doing" "todo" "inbox" "waiting" "done" "cancelled"))
        (todo--rank (or (plist-get t 'priority) "B") '("A" "B" "C"))
        (todo--date-num (plist-get t 'deadline))
        (or (plist-get t 'created) "")))

(define (todo--sort ts)
  (map cadr (sort (map (lambda (t) (list (todo--sort-key t) t)) ts))))

(define (todo--sort-trees ts)
  "TS, already in status order with parents pulled in, regrouped so each
   tree of the list stays together and the trees go in the order of the
   most urgent task in each. A done parent pulled in for an open child no
   longer puts its tree out of place. Inside a tree the order stays."
  (let* ((ids (map (lambda (t) (plist-get t 'id)) ts))
         (by-id (map (lambda (t) (list (plist-get t 'id) t)) ts))
         (root-of (lambda (t)
                    (let loop ((t t) (n 0))
                      (let ((pid (plist-get t 'parent)))
                        (if (and pid (member pid ids) (< n 50))
                            (loop (cadr (assoc pid by-id)) (+ n 1))
                            (plist-get t 'id))))))
         (roots (fold (lambda (acc t) (let ((r (root-of t))) (if (member r acc) acc (append acc (list r))))) '() ts))
         (members (lambda (r) (filter (lambda (t) (equal? (root-of t) r)) ts)))
         (best (lambda (r) (car (sort (map todo--sort-key (members r))))))
         (ordered (map caddr (sort (map (lambda (r i) (list (best r) i r)) roots (iota (length roots)))))))
    (apply append (map members ordered))))

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
  (reverse
    (fold (lambda (acc p) (if (or (todo--blank? p) (member p acc)) acc (cons p acc)))
          (list todo-default-project)
          (append (map todo--file-project (filter (lambda (f) (not (todo--group-path? f))) (todo--files)))
                  (map (lambda (t) (plist-get t 'project)) (todo--all))))))

(category! 'writing)
(public! 'todo-get "(todo-get ID) — one task as a plist, or #f")
(public! 'todo-list "(todo-list [SPEC]) — tasks, most urgent first; SPEC keys: state, all, project, assignee (none = unassigned), tag, text, due-before, overdue, ready, parent, source")
(public! 'todo-next "(todo-next WHO [SPEC]) — the most urgent ready task for WHO, else an unassigned one; #f when none")
(public! 'todo-projects "(todo-projects) — every project name")
(public! 'todo-ready? "(todo-ready?) — #t when the todo files are found, so a list costs no walk of the folders")

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
  "(todo-create TITLE PROPS) — file a task; return its id. PROPS must hold group, a group name or id: the task shows in that group's todo list, and assigning starts the chat there. Without it, or with an unknown one, it errors with the groups to pick from. PROPS may also hold project, state (default inbox), assignee, priority, deadline, scheduled, tags, source, parent, depends, goal, notes, by. A source already filed is not filed twice: that task's id comes back."
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
                        'project (todo--slug (or (plist-get props 'project) todo-default-project))
                        'notes (or (plist-get props 'notes) "")
                        'goal (todo--norm 'goal (plist-get props 'goal))
                        'extra '()
                        'log (list (todo--log-line who "created")))))
          (when (todo--blank? (plist-get t 'title)) (todo--fail "a task needs a title"))
          (todo--append! (todo--group-file group) (todo--render t))
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
        ;; the goal is one line: what is true when the task is done
        ((equal? k 'goal) (if (todo--blank? v) #f (string-join (todo--words (string-join (split-lines v) " ")) " ")))
        ((equal? k 'title) (if (todo--blank? v) (todo--fail "a task needs a title") (string-trim v)))
        ((todo--blank? v) #f)
        (else v)))

(define (todo--show v)
  (cond ((not v) "-") ((null? v) "-") ((pair? v) (string-join v " ")) (else v)))

(define (todo--change k old new)
  (cond ((equal? k 'notes) "notes edited")
        ((equal? k 'goal) "goal set")
        ((equal? k 'status) "status updated")
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

;; A sub-task that goes to review, done, waiting or cancelled says so in its
;; parent's log, with the first line of what it said, so whoever works the
;; parent sees the result without reading the sub-task's chat.
(define (todo--tell-parent! old new who text)
  (let ((parent (plist-get new 'parent))
        (state (plist-get new 'state)))
    (when (and (string? parent) (not (todo--blank? parent))
               (not (equal? state (plist-get old 'state)))
               (member state '("review" "done" "waiting" "cancelled"))
               (todo-get parent))
      (let* ((said (if (todo--blank? text) "" (car (string-split text "\n"))))
             (said (if (> (string-length said) 300) (string-append (substring said 0 300) "...") said)))
        (todo-update parent
          (list 'log (string-append "sub-task " (plist-get new 'id) " " (plist-get new 'title) " -> " state
                                    (if (todo--blank? said) "" (string-append ": " said)))
                'by who))))))

;; todo-state-functions: each runs as (FN OLD NEW WHO TEXT) when a task changes state;
;; OLD and NEW are the task before and after, TEXT the log line that came with the move.
(define (todo-update id props)
  "(todo-update ID PROPS) — change a task; return it. PROPS: any of title, state, project, assignee, chats, priority, urgent (#t or #f), deadline, scheduled, tags, source, parent, depends, goal (one line: what is true when it is done), notes (#f or blank clears one), status (what is done and what is left; it replaces the old), plus note (text added to the notes), log (a line for the log) and by (who). Each change is logged."
  (let* ((t (todo--must id))
         (who (or (plist-get props 'by) todo-user))
         (props (todo--split-log props)))
    (when (todo--has-key? props 'state)
      (todo--check-move! t (todo--norm 'state (plist-get props 'state))))
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
                  ;; a task lives in its group's folder: a new group moves it there,
                  ;; and so does any change to a task still in an old project file
                  (if (equal? (todo--group-file (plist-get new 'group)) (plist-get t 'file))
                      (todo--write-span! t (todo--render new))
                      (begin (todo--write-span! t #f)
                             (todo--append! (todo--group-file (plist-get new 'group)) (todo--render new))))
                  (todo--tell-parent! t new who text)
                  ;; a source (Linear, mail, ...) hears its task move: (FN OLD NEW WHO TEXT)
                  (unless (equal? (plist-get t 'state) (plist-get new 'state))
                    (run-hook-with-args 'todo-state-functions t new who text))
                  (todo-get id))))))))

;; What a log, done, wait or review call answers: the task's state after
;; the write and the last log line, not the whole task with its notes.
(define (todo--answer t)
  (list 'id (plist-get t 'id) 'state (plist-get t 'state)
        'assignee (plist-get t 'assignee)
        'log (let ((l (plist-get t 'log))) (if (pair? l) (car (reverse l)) #f))))

(define (todo-log id text &optional who)
  "(todo-log ID TEXT [WHO]) — add a line to the task's log"
  (todo--answer (todo-update id (list 'log text 'by (or who todo-user)))))

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

;; the summary a task ends a stage with is its status: what is done and what
;; is left, so the page alone hands the task over. A blank one keeps the old.
(define (todo--result-status text)
  (if (todo--blank? text) '() (list 'status text)))

(define (todo-done id &optional result who)
  "(todo-done ID [RESULT] [WHO]) — close the task as done; RESULT goes to the log"
  (todo--answer (todo-update id (append (list 'state "done" 'log result 'by (or who todo-user)) (todo--result-status result)))))

(define (todo-cancel id &optional reason who)
  "(todo-cancel ID [REASON] [WHO]) — close the task as cancelled"
  (todo-update id (list 'state "cancelled" 'log reason 'by (or who todo-user))))

(define (todo-wait id reason &optional who)
  "(todo-wait ID REASON [WHO]) — park the task: waiting on someone or something"
  (todo--answer (todo-update id (list 'state "waiting" 'log reason 'by (or who todo-user)))))

(define (todo-review id summary &optional who)
  "(todo-review ID SUMMARY [WHO]) — hand the task to a human to approve, e.g. a draft before it is sent"
  (todo--answer (todo-update id (append (list 'state "review" 'log summary 'by (or who todo-user)) (todo--result-status summary)))))

(define (todo-approve id &optional text who)
  "(todo-approve ID [TEXT] [WHO]) — approve a task in review: back to todo for its assignee, logged as approved"
  (todo-update id (list 'state "todo"
                        'log (if (todo--blank? text) "approved" (string-append "approved: " text))
                        'by (or who todo-user))))

(define (todo-reopen id &optional reason who)
  "(todo-reopen ID [REASON] [WHO]) — open a done or cancelled task again: back to todo, logged as reopened"
  (let ((t (todo--must id)))
    (unless (member (plist-get t 'state) *todo-closed*)
      (todo--fail id " is " (plist-get t 'state) ", not closed; only a done or cancelled task reopens"))
    (todo--answer
      (todo-update id (list 'state "todo"
                            'log (if (todo--blank? reason) "reopened" (string-append "reopened: " reason))
                            'by (or who todo-user))))))

;; A task's source is where the org tracks the work: "linear:SMA-109", a mail,
;; an ATS card. The task is our share of it, and a source has one task for
;; good: when the source comes back after our share closed, the same task
;; opens again and its chat wakes. A kind of source names the page that
;; shows a key, so a page's own chat can take the task.
;; a reload keeps what other packages registered
(define *todo-source-pages* (if (boundp '*todo-source-pages*) *todo-source-pages* '()))

(define (todo-source-page-register! prefix fn)
  "(todo-source-page-register! PREFIX FN) — a source key starting PREFIX shows on the page (FN KEY)"
  (set! *todo-source-pages*
        (cons (list prefix fn) (filter (lambda (e) (not (equal? (car e) prefix))) *todo-source-pages*)))
  prefix)

;; A kind of source also says how to open it beside the task: (FN KEY).
;; A key with no opener opens its page when that is up, or a URL in browse.
(define *todo-source-openers* (if (boundp '*todo-source-openers*) *todo-source-openers* '()))

(define (todo-source-opener-register! prefix fn)
  "(todo-source-opener-register! PREFIX FN) — a source key starting PREFIX opens with (FN KEY)"
  (set! *todo-source-openers*
        (cons (list prefix fn) (filter (lambda (e) (not (equal? (car e) prefix))) *todo-source-openers*)))
  prefix)

(define (todo-source-open! key)
  "(todo-source-open! KEY) — open the source KEY beside the task: its opener, else its open page, else a URL in browse; #f when nothing opens it"
  (and (string? key) (not (todo--blank? key))
       (let ((hit (find (lambda (e) (string-prefix? (car e) key)) *todo-source-openers*))
             (page (todo--source-page (list 'source key))))
         (cond (hit ((cadr hit) key) #t)
               (page (display-buffer-other-window! page) #t)
               ((or (string-prefix? "http://" key) (string-prefix? "https://" key))
                (browse-other-window key) #t)
               (else #f)))))

(define (todo--source-page t)
  ;; the open page that shows T's source, or #f
  (let ((key (plist-get t 'source)))
    (and (string? key)
         (let ((hit (find (lambda (e) (string-prefix? (car e) key)) *todo-source-pages*)))
           (and hit (let ((p ((cadr hit) key))) (and (string? p) (buffer-exists? p) p)))))))

(define (todo-of-source key)
  "(todo-of-source KEY) — the task filed from the source KEY, open or closed, the newest of several, or #f"
  (and (string? key)
       (let ((ts (todo-list (list 'source key 'all #t))))
         (and (pair? ts)
              (fold (lambda (t best) (if (string>? (or (plist-get t 'created) "") (or (plist-get best 'created) "")) t best))
                    (car ts) (cdr ts))))))

(define (todo-source-returned! id reason &optional who)
  "(todo-source-returned! ID REASON [WHO]) — the task's source came back for REASON. A done, reviewed or waiting task goes to doing, and its chat wakes with REASON, or a new chat takes it; a cancelled task stays, an open one only logs REASON. Answers the chat, or #f"
  (let* ((t (todo--must id)) (state (plist-get t 'state)) (who (or who todo-user)))
    (cond
      ((equal? state "cancelled")
       (todo-log id (string-append "back from its source, stays cancelled: " reason) who)
       #f)
      ((member state '("done" "review" "waiting"))
       (when (equal? state "done") (todo-reopen id "its source came back" who))
       (todo-update id (list 'state "doing" 'log (string-append "back from its source: " reason) 'by who))
       (let* ((t (todo-get id))
              (text (string-append "Your todo " id " is open again. " reason))
              (live (todo--chat-of t))
              (chat (or live (todo-assign-chat! id (plist-get t 'group)))))
         (when chat (agent-wake! chat "todo" text))
         chat))
      (else (todo-log id (string-append "from its source: " reason) who) #f))))

(define (todo-source-rounds t)
  "(todo-source-rounds TASK) — how many times the task's source came back"
  (length (filter (lambda (l) (string-contains? l "back from its source:")) (or (plist-get t 'log) '()))))

;;; --- the list ----------------------------------------------------------------

(category! 'writing)
(public! 'todo-create "(todo-create TITLE PROPS) — file a task; answers its id. PROPS must hold 'group, a group name or id (\"put a todo in X\" is group X); 'by is the name the change is logged under")

(define (todo-move-to-groups!)
  "(todo-move-to-groups!) — move every task out of the project files into its group's folder, groups/<id>/todos.md. Each old file is first copied to todos.md.moved; a task with no group stays in it, and a file left empty goes. A file with unsaved edits is not touched. Answers (moved N stayed N files (PATH ...) kept (PATH ...))"
  (let ((moved 0) (stayed 0) (files '()) (kept '()))
    (for-each
      (lambda (f)
        (if (and (buffer-exists? f) (buffer-modified? f))
            (set! kept (cons f kept))
            (let* ((tasks (todo--parsed f))
                   (loose (filter (lambda (t) (todo--blank? (plist-get t 'group))) tasks)))
              (when (< (length loose) (length tasks))
                (copy-file! f (string-append f ".moved"))
                (for-each (lambda (t)
                            (unless (todo--blank? (plist-get t 'group))
                              (todo--append! (todo--group-file (plist-get t 'group)) (todo--render t))
                              (set! moved (+ moved 1))))
                          tasks)
                (when (buffer-exists? f) (buffer-kill! f))
                (if (null? loose)
                    (delete-file f)
                    (write-file! f (string-append "# " (todo--file-project f) "\n\n"
                                                  (string-join (map todo--render loose) "\n\n") "\n")))
                (set! stayed (+ stayed (length loose)))
                (set! files (cons f files))))))
      ;; the folders as they are now, not the cached list a rescan refreshes later
      (filter (lambda (f) (and (file-exists? f) (not (todo--group-path? f)))) (todo--resolve)))
    (set! *todo-files* #f)
    (set! *todo-parse-cache* '())
    (todo--changed!)
    (list 'moved moved 'stayed stayed 'files (reverse files) 'kept (reverse kept))))

(define (todo-adopt-file! path g)
  "(todo-adopt-file! PATH G) — file the tasks of the todos.md at PATH in group G, as group-import! does with a group's own todos; a task whose id is already here stays out. Answers how many came in"
  (let* ((id (todo--group-of g))
         (known (map (lambda (t) (plist-get t 'id)) (todo--all)))
         (n 0))
    (for-each (lambda (t)
                (unless (member (plist-get t 'id) known)
                  (todo--append! (todo--group-file id) (todo--render (plist-put t 'group id)))
                  (set! n (+ n 1))))
              (todo--parse path (todo--text path)))
    n))
(public! 'todo-move-to-groups! "(todo-move-to-groups!) — move every task from the project files into its group's folder; keeps each old file as todos.md.moved")
(public! 'todo-adopt-file! "(todo-adopt-file! PATH G) — file the tasks of the todos.md at PATH in group G; answers how many came in")
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
  (filter (lambda (b) (equal? (buffer-local-value 'list-mode b) "todo-mode")) (buffer-list-mru)))

(define (todo--list-buffer)
  "the todo list a command acts on: this one, else the one used last"
  (if (equal? (buffer-local-value 'list-mode (current-buffer)) "todo-mode")
      (current-buffer)
      (let ((bs (todo--buffers))) (and (pair? bs) (car bs)))))

(define (todo--refresh-all!)
  (for-each (lambda (b)
              (list-refresh! b))
            (todo--buffers)))

;; the list and its task page are one app, an instance per group, laid out
;; by role as apps are: the list in one window, the page in the next
(define (todo--app-id group) (string-append "todo:" (or group "none")))

(define (todo--group-buffer mode base group)
  "the MODE buffer GROUP keeps, like chat-menu and ibuffer; made from BASE when it has none"
  (let ((buf (or (find (lambda (b) (and (equal? (buffer-local-value 'mode-name b) mode) (equal? (buffer-group b) group)))
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
  (list (list "open" '(state ("review" "doing" "todo" "waiting")))
        (list "inbox" '(state "inbox"))
        (list "waiting" '(state "waiting"))
        (list "closed" '(state ("done" "cancelled")))
        (list "all" '(all #t))))

(define (todo--view buf) (list-tab buf "open"))

(define (todo--view-spec buf)
  (cadr (or (assoc (todo--view buf) *todo-views*) (car *todo-views*))))

;; `/` narrows by words, all of which must hit: p:PROJECT, g:GROUP, s:STATE,
;; @ASSIGNEE, #TAG, !PRIORITY, or any text of the task
(define (todo--match buf t input)
  (let* ((s (lambda (k) (let ((v (plist-get t k))) (if (string? v) v ""))))
         (has? (lambda (hay w) (or (equal? w "") (completion-match? hay w 'substring))))
         (after (lambda (w n) (substring-bytes w n (string-byte-length w))))
         (tags (string-join (or (plist-get t 'tags) '()) " "))
         ;; the group by its name, as the list shows it
         (group (let ((g (plist-get t 'group))) (if (string? g) (or (group-name g) g) "")))
         (hay (string-join (list (s 'title) (s 'project) group (s 'state) (s 'assignee) tags
                                 (s 'source) (s 'notes) (s 'id)) " ")))
    (null? (remove (lambda (w)
             (cond ((string-prefix? "p:" w) (has? (s 'project) (after w 2)))
                   ((string-prefix? "g:" w) (has? group (after w 2)))
                   ((string-prefix? "s:" w) (has? (s 'state) (after w 2)))
                   ((string-prefix? "@" w) (has? (s 'assignee) (after w 1)))
                   ((string-prefix? "#" w) (has? tags (after w 1)))
                   ((string-prefix? "!" w) (has? (s 'priority) (after w 1)))
                   (else (has? hay w))))
           (string-split input " ")))))

(define *todo-sorts* '("status" "urgency" "deadline" "created" "active"))

(define (todo--last-active t)
  "The time of T's newest log line, else its creation time, as YYYY-MM-DD HH:MM."
  (car (reverse (sort (cons (or (plist-get t 'created) "")
                            (map (lambda (line) (if (>= (string-length line) 16) (substring line 0 16) ""))
                                 (or (plist-get t 'log) '())))))))

(define (todo--sort-by buf) (list-sort buf "status"))

(define (todo--resort ts by)
  "urgency: time-sensitive first, then status. deadline: soonest first, undated last. created: newest first. active: last touched first. status: todo-list's own order."
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
        ((equal? by "active")
         (reverse (map cadr (sort (map (lambda (t) (list (todo--last-active t) t)) ts)))))
        (else ts)))

(define (todo--with-parents ts)
  ;; a tab shows the parent of every task it shows, whatever the parent's own
  ;; state, so a client's inbox tasks sit under the client in the inbox tab
  ;; too. Each missing ancestor lands just before its first descendant.
  (let* ((all (todo--all))
         (by-id (lambda (id) (find (lambda (t) (equal? (plist-get t 'id) id)) all)))
         (seen (map (lambda (t) (plist-get t 'id)) ts))
         (out '()))
    (define (chain t acc)
      (let* ((pid (plist-get t 'parent))
             (p (and pid (not (member pid seen)) (not (member pid (map car acc))) (by-id pid))))
        (if p (chain p (cons (list pid p) acc)) acc)))
    (for-each (lambda (t)
                (for-each (lambda (pr) (set! seen (cons (car pr) seen)) (set! out (cons (cadr pr) out)))
                          (chain t '()))
                (set! out (cons t out)))
              ts)
    (reverse out)))

(define (todo--rows buf)
  (let* ((by (todo--sort-by buf))
         (ts (todo--with-parents (todo--resort (todo-list (todo--view-spec buf)) by))))
    (list-keep buf (todo--sections buf (if (equal? by "status") (todo--sort-trees ts) ts)))))

;;; `<` cycles what a section is; a section heading is a row of kind sep
(define *todo-groupings* '("none" "group" "project" "status"))

(define (todo--grouping buf) (or (buffer-local-value 'todo-grouping buf) "none"))

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
      (let* ((names (reverse
                      (fold (lambda (acc t) (let ((n (todo--section-of buf t))) (if (member n acc) acc (cons n acc))))
                            '() ts))))
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
  (let ((k (car f)) (v (car (cdr f)))
        (s (lambda (key) (let ((x (plist-get t key))) (if (string? x) x "")))))
    (cond ((todo--sep? t) #t)
          ((equal? k "group") (equal? (plist-get t 'group) v))
          ((equal? k "project") (equal? (plist-get t 'project) v))
          ((equal? k "state") (equal? (plist-get t 'state) v))
          ;; the f prefix filters, as ibuffer's are
          ((equal? k "assignee") (equal? (plist-get t 'assignee) v))
          ((equal? k "tag") (and (member v (or (plist-get t 'tags) '())) #t))
          ((equal? k "priority") (equal? (s 'priority) v))
          ((equal? k "title") (completion-match? (s 'title) v 'substring))
          ((equal? k "content") (completion-match? (string-append (s 'title) " " (s 'notes)) v 'substring))
          ((equal? k "not") (not (list-filter-match? buf t (nth 2 f))))
          ((equal? k "or") (or (list-filter-match? buf t (nth 2 f)) (list-filter-match? buf t (nth 3 f))))
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
              ;; the views, then every state that is not a view of its own
              'options (lambda (buf)
                         (let ((views (map car (alist-delete *todo-views* "all"))))
                           (map (lambda (v) (list v v))
                                (append views (remove (lambda (s) (member s views)) *todo-states*)))))
              'get (lambda (buf)
                     (let ((s (assoc "state" (list-filters buf))) (v (todo--view buf)))
                       (cond (s (cadr s)) ((equal? v "all") #f) (else v))))
              ;; a view takes its tab; a single state filters the all tab
              'set (lambda (buf v)
                     (todo--state-drop! buf)
                     (cond ((or (not v) (assoc v *todo-views*)) (list-tab-set! buf (or v "all")))
                           (else (list-tab-set! buf "all")
                                 (buffer-set-local! buf 'list-filters
                                   (cons (list "state" v) (list-filters buf)))))))))

(define (todo--state-drop! buf)
  "taking a status tab drops the single-state filter the Status facet set"
  (buffer-set-local! buf 'list-filters (alist-delete (list-filters buf) "state")))

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
        (list "" 1)
        (list "TODO" #f 'left 'end)
        (list "PROJECT" 14 'left 'end)
        (list "WHO" 24 'left 'end)
        (list "DUE" 12)))

(define (todo--narrow-columns buf)
  ;; a narrow window keeps ibuffer's one line a task, without who and when
  (list (list "STATE" 7)
        (list "" 1)
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
          (list (if (plist-get t 'urgent) "!" "") "todo-overdue")
          (list (plist-get t 'title) (if (member s *todo-closed*) "f-dim" "ibuffer-name"))
          (list (todo--short-project t) "f-dim")
          ;; a chat that closed leaves only its id behind, which says nothing
          (list (let* ((w (todo--who t)))
                  (if (string-prefix? "chat:" w) "chat closed" w))
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
                                        (todo--chip (todo--last-update t) "org-meta"))))
              (list "")))))

(define (todo--at) (let ((t (list-current (todo--list-buffer)))) (and t (not (todo--sep? t)) t)))

(define (todo--keep-place! f)
  "run F, which may change the task at point, and redraw; list-mode keeps the highlight on the same task, wherever the order puts it"
  (f)
  (list-refresh! (todo--list-buffer)))

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
    (lambda (t) (todo--set-one! t k v todo-user))))

(define (todo--set-one! t k v who)
  ;; a state move the machine refuses skips this task with a word, so a
  ;; batch of marked tasks still moves the ones that can
  (cond ((and (equal? k 'state) (not (todo-can-move? (plist-get t 'state) v)))
         (message (string-append (plist-get t 'title) ": " (plist-get t 'state) " cannot go to " v)) #f)
        ((and (equal? k 'state) (equal? v "todo") (member (plist-get t 'state) *todo-closed*))
         (todo-reopen (plist-get t 'id) #f who) #t)
        (else (todo-update (plist-get t 'id) (list k v 'by who)) #t)))

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
          (message "No task at point"))))
  'modes '(todo-mode))

(define-command "todo-accept" "Mark the task todo: triage it, approve it from review, or reopen it"
  (lambda () (todo--set-at! 'state "todo"))
  'modes '(todo-mode))
(define-command "todo-mark-done" "Mark the task done"
  (lambda () (todo--set-at! 'state "done"))
  'modes '(todo-mode))
(define-command "todo-mark-cancelled" "Cancel the task"
  (lambda () (todo--set-at! 'state "cancelled"))
  'modes '(todo-mode))
(define-command "todo-mark-waiting" "Park the task as waiting"
  (lambda () (todo--set-at! 'state "waiting"))
  'modes '(todo-mode))
;; the task's chat, kept or new, shown beside OWNER; the focus stays
(define (todo--start-chat! t owner)
  (let ((chat (or (todo--revive-chat t)
                  (todo-assign-chat! (plist-get t 'id) (or (todo--home-group t) (group-here))))))
    (todo--show-chat-beside! chat owner)))

(define-command "todo-mark-doing" "Mark the task in progress, and open its chat; marked tasks only change state"
  (lambda ()
    (let ((t (todo--at)) (marked (todo--marked-tasks)))
      (todo--set-at! 'state "doing")
      (when (and t (null? marked))
        (todo--start-chat! (todo-get (plist-get t 'id)) (current-buffer)))))
  'modes '(todo-mode))

(define-command "todo-mark-inbox" "Send the task back to the inbox, to triage again"
  (lambda () (todo--set-at! 'state "inbox"))
  'modes '(todo-mode))

(define-command "todo-toggle-urgent" "Mark the task time-sensitive, or not"
  (lambda ()
    (todo--with-tasks "Toggle urgent on"
      (lambda (t)
        (todo-update (plist-get t 'id) (list 'urgent (not (plist-get t 'urgent)))))))
  'modes '(todo-mode))

(define-command "todo-cycle-priority" "Cycle the task's priority: A, B, C, none"
  (lambda ()
    (todo--with-tasks "Cycle the priority of"
      (lambda (t)
        (let ((p (plist-get t 'priority)))
          (todo-update (plist-get t 'id)
                       (list 'priority (cond ((not p) "A") ((equal? p "A") "B") ((equal? p "B") "C") (else #f))))))))
  'modes '(todo-mode))

;; assigning hands the task to a fresh chat in a group: the chat is the
;; assignee, and its first message is the brief
(define (todo--brief t chat)
  (let* ((id (plist-get t 'id))
         (field (lambda (label k) (let ((v (plist-get t k)))
                                    (if (todo--blank? v) "" (string-append label ": " v "\n")))))
         (notes (plist-get t 'notes)))
    (string-append
     "You are assigned todo " id ": " (plist-get t 'title) "\n\n"
     (field "Project" 'project) (field "Deadline" 'deadline) (field "Source" 'source) (field "Goal" 'goal)
     (if (todo--blank? notes) "" (string-append "\nNotes:\n" notes "\n"))
     (if (todo--blank? (plist-get t 'status)) "" (string-append "\nStatus (done and left):\n" (plist-get t 'status) "\n"))
     "\nRead it with (todo-get \"" id "\"). Work it through the todo API as \"" chat "\":\n"
     (if (todo--blank? notes)
         (string-append "- first, before other work, write the task's notes, the brief: what to do, why, and the rules, from the title and what you find: (todo-update \"" id "\" (list 'notes TEXT 'by \"" chat "\"))\n")
         "")
     (if (todo--blank? (plist-get t 'goal))
         (string-append "- first, set its goal, one line that says what is true when it is done: (todo-update \"" id "\" (list 'goal TEXT 'by \"" chat "\"))\n")
         "")
     "- (todo-log \"" id "\" TEXT \"" chat "\") for progress\n"
     "- (todo-update \"" id "\" (list 'status TEXT 'by \"" chat "\")) when what is done or left changes; TEXT replaces the status\n"
     "- (todo-review \"" id "\" SUMMARY \"" chat "\") before anything goes out, and stop there\n"
     "- (todo-wait \"" id "\" REASON \"" chat "\") when it waits on someone\n"
     "  then (agent-listen! '(topic \"whatsapp:PHONE\" kind received task \"" id "\") NOTE), so the reply wakes you; a mail:ACCOUNT topic needs 'match with the sender\n"
     "- (todo-done \"" id "\" RESULT \"" chat "\") when it is finished\n"
     "If you saved files, call (jj-describe! TEXT) before todo-review or todo-done; TEXT follows docs/COMMITS.md.\n"
     "Coordinate with other chats through holds, never through messages: long work that a hot reload would break takes (hold! 'reload WHY), which answers an id for (release! ID); shell-job! takes the holds of a mix test itself. When a save or a test says a hold is open, call (agent-listen! '(topic \"holds\" kind released) NOTE) and try again when it wakes you. (holds) lists them.\n"
     "Never end a turn while you wait on background work (tests, a task) without a wake-up: first (agent-listen! '(at \"YYYY-MM-DD HH:MM\") NOTE), or a listener on the event you wait for. Else nothing wakes you.\n"
     "When it is finished, call (chat-finish! 'done RESULT): the chat closes itself. If it cannot finish, call (chat-finish! 'blocked WHY) or (chat-finish! 'needs-user WHAT).\n")))

(define (todo-assign-chat! id group &optional who)
  "(todo-assign-chat! ID GROUP [WHO]) — hand the task to its chat in GROUP (assign-chat!: its live assignee chat unless that is the caller, else a new one), make that chat the assignee and send it the brief when the chat is new. A kept chat whose backend is gone, or whose connector is not the group's now, gives way to a new chat. A new chat shows in no window until someone asks for it. A chat a person starts is in the chat lists once the command ends; a chat an agent starts (the eval's agent, or WHO agent:SLUG) is its subagent with notify and stays out of the lists until . asks; return the chat"
  (let* ((t (todo--must id))
         (g (or (group-resolve-id group) (group-ensure-record! group)))
         ;; the chat whose eval starts the task, else the agent WHO names
         (caller (or (subagent-spawner)
                     (and (string? who) (string-prefix? "agent:" who)
                          (substring who 6 (string-length who)))))
         ;; the task's own chat is the open one kept for it, else its live
         ;; assignee, never the chat that last logged on it: that one can be
         ;; the orchestrator, the caller. An archived chat is not read back:
         ;; its backend is gone, and reading it would show it.
         (own (or (todo--kept-live t g)
                  (let ((a (plist-get t 'assignee)))
                    (and (string? a) (string-prefix? "chat:" a) (todo--live-chat a)))))
         ;; a task with no chat of its own, whose source page has its own chat
         ;; open, goes to that chat: one chat works an issue
         (adopted (and (not own)
                       (let ((p (todo--source-page t)))
                         (and p (let ((c (llm-mode--companion-existing p))) (and (string? c) (chat-buffer? c) c))))))
         (held (or (and own (not (and caller (equal? (subagent-slug own) caller)))
                        (todo--chat-current? own g) own)
                   adopted)))
    (let* ((got (assign-chat! #f g
                  (lambda (chat)
                    ;; the caller hears when the new chat stops
                    (when caller (buffer-set-local! chat 'subagent-notify #t))
                    (todo-update id (list 'assignee (chat-stable-id! chat)
                                          'state (if (member (plist-get t 'state) '("inbox" "todo")) "doing" (plist-get t 'state))
                                          'log (string-append "assigned to a chat in " (group-name g))
                                          'by (or who todo-user)))
                    (todo--brief (todo-get id) (chat-stable-id! chat)))
                  held))
           (chat (car got)))
      ;; the source page's chat takes the task as a new chat would: the
      ;; assignee, and the brief
      (when (and adopted (not (cadr got)) (equal? chat adopted))
        (todo-update id (list 'assignee (chat-stable-id! chat)
                              'state (if (member (plist-get t 'state) '("inbox" "todo")) "doing" (plist-get t 'state))
                              'log "the source page's own chat takes the task"
                              'by (or who todo-user)))
        (agent-continue! chat (todo--brief (todo-get id) (chat-stable-id! chat))))
      (when (cadr got)
        ;; a new chat takes no window until someone asks for it
        (buffer-context-only! chat)
        ;; and is the caller's subagent. Recorded after the brief started its
        ;; backend, so the edge names the chat's slug, not its buffer.
        (when caller (subagent-record! caller chat)))
      (todo--keep-chat! t chat g)
      ;; A new chat wears the task's title. Named here, after the brief went
      ;; out under the old name; the first-prompt title lands later and
      ;; leaves a titled chat alone. A chat a person started is in the chat
      ;; lists once the command ends; an agent's stays out until . asks.
      (let ((named
      (if (and (cadr got) (string? (plist-get t 'title)))
          (let ((sid (chat-stable-id! chat)))
            (if (chat-title chat (plist-get t 'title))
                ;; chat-title may have settled on "Title<2>"; find the renamed
                ;; buffer by its stable id
                (or (find (lambda (b) (and (string? (buffer-local-value 'chat-title b))
                                           (equal? (chat-stable-id! b) sid)))
                          (group-buffers g))
                    chat)
                chat))
          chat)))
        (when (and (cadr got) (not caller)) (chat-quiet! named #t))
        named))))

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
                                   (let* ((slug (buffer-local-value 'agent-slug b))
                                          (id (or (buffer-local-value 'chat-id b)
                                                  (and (string? slug) (string-prefix? "chat-" slug)
                                                       (string-append "chat:" (string-join (cdr (string-split slug "-")) ":"))))))
                                     (if (string? id) (cons (list id b) acc) acc)))
                                 '() (buffer-list)))))
          (set! *todo-chat-index* (cons now ix))
          ix))))

(define (todo--live-chat id)
  ;; asleep counts: a sleeping chat wakes when it is used
  (and (string? id)
       (let ((hit (assoc id (todo--chat-index))))
         (if hit
             (cadr hit)
             (let ((found (chat-list (list 'chat-ids (list id)))))
               (and (pair? found) (car found)))))))

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
                 ;; only a chat that moved the task's state worked it; filing,
                 ;; parenting, projects and notes do not make a task a chat's
                 (and (>= (length words) 4)
                      (equal? (list-ref words 3) "state")
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

(define (todo--kept-chat t &optional group)
  ;; the chat kept for the task, in GROUP or its home group: live, else read
  ;; back from its file, else #f
  (let ((home (todo--home-group t)))
    (or (and group (chat-for (plist-get t 'id) group))
        (and home (not (equal? home group)) (chat-for (plist-get t 'id) home)))))

(define (todo--keep-chat! t chat g)
  ;; the task keeps CHAT across archives and restarts, unless CHAT is kept
  ;; for another thing
  (let ((k (chat-for-key chat g)))
    (when (or (not k) (equal? k (plist-get t 'id)))
      (chat-for! (plist-get t 'id) chat g))))

(define (todo--kept-live t g)
  ;; the chat kept for the task in G or its home group, only when it is open
  (let ((id (plist-get t 'id)))
    (let loop ((gs (list g (todo--home-group t))))
      (and (pair? gs)
           (or (let ((p (and (car gs) (alist-get (chat-for--index (car gs)) id))))
                 (and (string? p) (chat-for--live p)))
               (loop (cdr gs)))))))

(define (todo--chat-current? chat g)
  ;; a chat goes on with a task only when its backend still runs and it
  ;; speaks through the connector the group starts its chats with now
  (let* ((slug (buffer-local-value 'agent-slug chat))
         (b (llm-group-bundle g))
         (want (or (and b (plist-get b 'connector)) *default-connector*)))
    (and (string? slug)
         (not (eq? (agent-status slug) 'dead))
         (equal? (or (buffer-local-value 'agent-connector chat) *default-connector*) want))))

(define (todo--revive-chat t)
  ;; the task's chat: live, else the chat kept for it, else its archived
  ;; conversation read back in the task's group, else #f
  (or (todo--chat-of t)
      (todo--kept-chat t)
      (let ((a (plist-get t 'assignee)))
        (and (string? a) (string-prefix? "chat:" a)
             (todo--open-chat a (or (todo--home-group t) (frame-group)))))))

(define (todo--chat-ref chat)
  ;; a chat's id, from the id itself or from its buffer
  (cond ((not (string? chat)) #f)
        ((string-prefix? "chat:" chat) chat)
        ((buffer-known? chat) (chat-stable-id! chat))
        (else #f)))

(define (todo-chats t)
  "(todo-chats TASK) — the task's chat as a list: its assignee chat id, or empty. A task has one chat"
  (let ((a (plist-get t 'assignee)))
    (if (and (string? a) (string-prefix? "chat:" a)) (list a) '())))

(public! 'todo-chats "(todo-chats TASK) — the task's chat as a list: its assignee chat id, or empty. A task has one chat")

;; Handover. The chat working a task is archived and a new chat in the
;; task's group takes it, with the task's notes as its brief: the task is
;; the record, so nothing else crosses. The new chat keeps the old one's
;; parent, so its reports reach the same coordinator. A chat that hands
;; over its own task is archived when its turn ends, not in the middle.
(define (todo--handover-now! id who)
  (let* ((t (todo--must id))
         (old-ref (plist-get t 'assignee))
         (g (or (plist-get t 'group) (todo--home-group t)))
         ;; the chat index is a second old at most; the chat the task keeps is not
         (old (or (todo--live-chat old-ref) (todo--kept-live t g)))
         (parent (and old (subagent-parent old))))
    ;; never close the chat the user is on; it stays, off the task
    (define kept? (and old (chat-user-focused? old)))
    (when (and old (not kept?)) (agents-archive! old))
    (todo-update id (list 'assignee #f
                          'chats (remove (lambda (c) (equal? c old-ref)) (or (plist-get t 'chats) '()))
                          'log (string-append "handed over: " (or old-ref "no chat")
                                              (cond (kept? " kept open, the user is on it") (old " archived") (else "")))
                          'by who))
    (todo-assign-chat! id g (if parent (string-append "agent:" parent) todo-user))))

(define (todo-handover! id &optional who)
  "(todo-handover! ID [WHO]) — archive the chat working the task, start a new chat in the task's group with the task as its brief, and make it the assignee; answers the new chat, or a note when the calling chat hands over its own task (that runs when its turn ends)"
  (let* ((t (todo--must id))
         (who (or who todo-user))
         (old (or (todo--live-chat (plist-get t 'assignee))
                  (todo--kept-live t (or (plist-get t 'group) (todo--home-group t)))))
         (slug (and old (agent-slug-of old))))
    (if (and slug (member (agent-status slug) '(running starting)))
        (begin (buffer-set-local! old 'todo-handover (list id who))
               "the handover runs when this chat's turn ends")
        (todo--handover-now! id who))))

(add-hook! (list 'agent-turn-end "todo-handover")
  (lambda (slug stop-reason ok?)
    (let* ((buf (agent-buf slug))
           (job (and (string? buf) (buffer-exists? buf) (buffer-local-value 'todo-handover buf))))
      (when job
        (buffer-set-local! buf 'todo-handover #f)
        (todo--handover-now! (car job) (cadr job))))))

(public! 'todo-handover! "(todo-handover! ID [WHO]) — archive the task's chat, start a new one with the task as its brief, and make it the assignee")
(catalog-meta! 'function "todo-handover!" 'domain 'writing 'effects '(destroy spend))

(define-command "todo-handover" "Hand the task to a new chat: archive the chat working it, start a new one with the task as its brief"
  (lambda ()
    (let ((t (if (equal? (buffer-local-value 'mode-name (current-buffer)) "todo-detail-mode")
                 (todo--detail-task (current-buffer))
                 (todo--at))))
      (if (not t)
          (message "No task here")
          (let ((new (todo-handover! (plist-get t 'id))))
            (message (if (string? new) (string-append "Handed over to " new) "No chat"))))))
  'modes '(todo-mode todo-detail-mode))

;; Reap. Close the chats of done and inbox tasks. A chat stays when an open task
;; still names it, when it runs a turn, or when the user is on it.
(define (todo--ref-buffer ref)
  (cond ((not (string? ref)) #f)
        ((string-prefix? "agent:chat-" ref)
         (todo--live-chat (string-append "chat:" (string-join (cdr (string-split (substring ref 6 (string-length ref)) "-")) ":"))))
        (else (todo--live-chat ref))))

(define (todo--task-chats t)
  (filter (lambda (b) (and (string? b) (buffer-exists? b)))
          (map todo--ref-buffer (cons (plist-get t 'assignee) (or (plist-get t 'chats) '())))))

(define (todo-reap-chats! &optional who)
  "(todo-reap-chats! [WHO]) — archive every live chat of a done or inbox task; keep a chat an open task names, a chat that runs a turn, and the chat the user is on; answer (CLOSED KEPT)"
  (let* ((open (apply append (map todo--task-chats
                                  (remove (lambda (t) (equal? (plist-get t 'state) "inbox")) (todo-list)))))
         (self (current-buffer))
         (cands (apply append (map todo--task-chats (append (todo-list '(state "done")) (todo-list '(state "inbox"))))))
         (closed '()) (kept '()))
    (for-each
     (lambda (b)
       (let ((slug (agent-slug-of b)))
         (cond
          ((or (member b closed) (member b kept)) #f)
          ((or (member b open) (equal? b self) (chat-user-focused? b)
                 (and slug (member (agent-status slug) '(running starting))))
           (set! kept (cons b kept)))
          (else (agents-archive! b) (set! closed (cons b closed))))))
     cands)
    (list (reverse closed) (reverse kept))))

(public! 'todo-reap-chats! "(todo-reap-chats! [WHO]) — archive every live chat of a done or inbox task, except a chat an open task names, a running chat and the chat the user is on; answer (CLOSED KEPT)")
(catalog-meta! 'function "todo-reap-chats!" 'domain 'writing 'effects '(destroy))

;; Dismiss. Put a task away: close its page and the chats that work it.
;; The state stays. A chat another open task still names stays open.
(define (todo-dismiss! id &optional who)
  "(todo-dismiss! ID [WHO]) — close the task's page and archive its chats, except a chat another open task names and the calling chat; answer the closed chats"
  (let* ((t (todo--must id))
         (others (apply append (map todo--task-chats
                                    (remove (lambda (o) (equal? (plist-get o 'id) id)) (todo-list)))))
         (self (current-buffer))
         (closed '()))
    (for-each
     (lambda (b)
       (unless (or (member b closed) (member b others) (equal? b self))
         (agents-archive! b)
         (set! closed (cons b closed))))
     (todo--task-chats t))
    (for-each
     (lambda (b)
       (when (and (equal? (buffer-local-value 'mode-name b) "todo-detail-mode")
                  (equal? (buffer-local-value 'todo-id b) id))
         (buffer-kill! b)))
     (buffer-list))
    (reverse closed)))

(public! 'todo-dismiss! "(todo-dismiss! ID [WHO]) — close the task's page and archive its chats, except a chat another open task names; answer the closed chats")
(catalog-meta! 'function "todo-dismiss!" 'domain 'writing 'effects '(destroy))

(define (todo--dismiss-msg r)
  (message (string-append "Dismissed; closed " (number->string (length r)) " chats")))

(define-command "todo-dismiss" "Dismiss the task: close its page and the chats that work it; the state stays"
  (lambda ()
    (let ((t (if (equal? (buffer-local-value 'mode-name (current-buffer)) "todo-detail-mode")
                 (todo--detail-task (current-buffer))
                 (todo--at))))
      (if t (todo--dismiss-msg (todo-dismiss! (plist-get t 'id))) (message "No task here"))))
  'modes '(todo-mode todo-detail-mode))

(define-command "todo-reap-chats" "Close every chat whose task is done or in the inbox; keep a chat an open task still uses, a running chat and the chat you are on"
  (lambda ()
    (let ((r (todo-reap-chats!)))
      (message (string-append "Closed " (number->string (length (car r))) " chats of done and inbox tasks"
                              (if (pair? (cadr r)) (string-append ", kept " (number->string (length (cadr r)))) ""))))))

(define (todo--chat-label c)
  ;; a live chat's name, else its archived title, else its id
  (or (todo--live-chat c)
      (let* ((path (todo--archived-chat c)) (title (and path (todo--chat-title path))))
        (and path (string-append (or title c) "  (archived)")))
      (string-append c "  (gone)")))

(define (todo--who t) (or (todo--chat-of t) (plist-get t 'assignee) ""))

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
  "show CHAT and focus it: where it already shows, else in a pane apart from this one that shows no chat, so it never covers the chat you type in"
  (let ((id (group-home-of chat)))
    (when (and id (not (equal? id (frame-group)))) (switch-to-group! id)))
  (let* ((shown (window-showing chat))
         (win (if (and shown (window-exists? shown))
                  shown
                  (panes-display-apart! chat (filter chat-buffer? (map cadr (window-list)))))))
    (when win (select-window! win))
    chat))

;; one task as its own page beside the list. Its chat is the assignee, the
;; chat that works the task, never the one that filed it
(define *todo-detail-buffer* "*Todo*")

(define (todo--detail-group)
  "the group a task page opens in: this todo list's, else the group you are in"
  (if (equal? (buffer-local-value 'list-mode (current-buffer)) "todo-mode")
      (buffer-group (current-buffer))
      (group-here)))

(define (todo--group-list group)
  "the todo list GROUP keeps, or #f; a page never opens beside another group's list"
  (find (lambda (b) (equal? (buffer-group b) group)) (todo--buffers)))

(define (todo--detail-buffer)
  "the task page of the group you are in, or #f; a group keeps its own"
  (let ((group (todo--detail-group)))
    (find (lambda (b) (and (equal? (buffer-local-value 'mode-name b) "todo-detail-mode") (equal? (buffer-group b) group)))
          (buffer-list-mru))))

(define (todo--detail-task buf)
  (let ((id (buffer-local-value 'todo-id buf)))
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
      (let ((chat (let ((b (todo--chat-of t))) (and b (buffer-local-value 'chat-id b)))))
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

(define (todo--detail-blocks t &optional tab)
  ;; (TEXT BLOCKS CHILD-LINES): every part of the page is one line of TEXT and an
  ;; anchor on it, so the arrows walk the page part by part and it scrolls along.
  ;; TAB picks the part: overview is status, notes and details, children the
  ;; sub-tasks, log the log. CHILD-LINES is ((LINE . ID) ...) of the sub-task rows.
  (let* ((tab (or tab "overview"))
         (chat (todo--chat-of t))
         (logs (or (plist-get t 'log) '()))
         (notes (plist-get t 'notes))
         (tags (plist-get t 'tags))
         (state (or (plist-get t 'state) "inbox"))
         (kids (todo--detail-children t))
         (lines '())
         (child-lines '())
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
         (actions (component 'ui/actions (list 'actions (todo--detail-actions tab state (plist-get t 'source)))))
         ;; where the task stands: what is done and what is left
         (status-part (lambda ()
                        (let ((s (plist-get t 'status)))
                          (if (todo--blank? s) '()
                              (let ((n (line! "Status")))
                                (list (stop (component 'ui/group
                                              (list 'title "Status" 'body (list (list 'tag "c-group" 'class "c-prose c-lines" 'text s))))
                                            "Status" n n)))))))
         (goal-part (lambda ()
                      (let ((g (plist-get t 'goal)))
                        (if (todo--blank? g) '()
                            (let ((n (line! "Goal")))
                              (list (stop (component 'ui/group
                                            (list 'title "Goal" 'body (list (list 'tag "c-group" 'class "c-prose c-lines" 'text g))))
                                          "Goal" n n)))))))
         (notes-part (lambda ()
                       (if (todo--blank? notes) '()
                           (let ((n (line! "Notes")))
                             (list (stop (component 'ui/group
                                           (list 'title "Notes" 'body (list (list 'tag "c-group" 'class "c-prose c-lines" 'text notes))))
                                         "Notes" n n))))))
         (details (lambda ()
                    (let ((n (line! "Details")))
                      (stop (component 'ui/group
                              (list 'title "Details"
                                    'body
                                    (list
                                      (component 'ui/kv
                                        (list 'pairs
                                          (append
                                            (pair "Chat" (if chat (string-append chat "  ·  M-o goes there") (plist-get t 'assignee)))
                                            (pair "Chat state" (todo--status t))
                                            (pair "Goal state" (todo--goal t))
                                            (pair "Parent" (let ((p (and (plist-get t 'parent) (todo-get (plist-get t 'parent)))))
                                                             (and p (plist-get p 'title))))
                                            (pair "Group" (group-name (plist-get t 'group)))
                                            (pair "Filed by" (plist-get t 'by))
                                            (pair "Source" (plist-get t 'source))
                                            (pair "Created" (plist-get t 'created))
                                            (pair "Id" (plist-get t 'id))))))))
                            "Details" n n))))
         (listening (lambda ()
                      (let ((ls (todo--listeners t)))
                        (if (null? ls) '()
                            (list (part (string-append "Listening  ·  " (number->string (length ls))) "Listening"
                                        (map todo--detail-listener ls)))))))
         ;; one row a sub-task: its title and its state. RET or a click
         ;; visits it; u comes back.
         (children (lambda ()
                     (if (null? kids)
                         (list (component 'ui/empty (list 'text "No sub-tasks")))
                         ;; a section heading over the rows names them
                         (let loop ((ks kids) (i 1)
                                    (acc (let ((h (line! "Children")))
                                           (list (stop (component 'ui/section (list 'title "Children" 'count (length kids)))
                                                       "Children" h h)))))
                           (if (null? ks) (reverse acc)
                               (let* ((k (car ks))
                                      (state (or (plist-get k 'state) "inbox"))
                                      (tone (todo--detail-tone state))
                                      (n (line! (plist-get k 'title))))
                                 (set! child-lines (cons (cons n (plist-get k 'id)) child-lines))
                                 (loop (cdr ks) (+ i 1)
                                       (cons (stop (component 'ui/row
                                                     (list 'class "todo-child"
                                                           'click (string-append "todo-child:" (plist-get k 'id))
                                                           'segs (list (list "todo-child-title" (or (plist-get k 'title) ""))
                                                                       (list (string-append "todo-child-state "
                                                                                            (if (equal? tone "") "c-dim" (string-append "c-" tone)))
                                                                             state))))
                                                   (string-append "Child " (number->string i)) n n)
                                             acc))))))))
         (log (lambda ()
                (if (null? logs)
                    (list (component 'ui/empty (list 'text "No log yet")))
                    (list (part (string-append "Log  ·  " (number->string (length logs))) "Log"
                                (map todo--detail-entry (reverse logs)))))))
         (body (cond ((equal? tab "children") (children))
                     ((equal? tab "log") (log))
                     (else (let* ((s (status-part)) (g (goal-part)) (n (notes-part)) (d (details)) (l (listening)))
                             (append s g n (list d) l))))))
    (list
      (string-join (reverse lines) "\n")
      (list
        (component 'ui/page
          (list 'body
            (append
              (list head (component 'ui/meta (list 'segs (todo--detail-facts t))))
              (if (and (pair? tags) (equal? tab "overview")) (list (component 'ui/chips (list 'items tags))) '())
              (list actions)
              body))))
      child-lines)))

(define *todo-detail-tabs* '(("overview" "Overview") ("children" "Children") ("log" "Log")))

(define (todo--detail-tab buf) (or (buffer-local-value 'todo-tab buf) "overview"))

(define (todo--detail-children t)
  "the sub-tasks of T, open and closed"
  (todo-list (list 'parent (plist-get t 'id) 'all #t)))

(define (todo--detail-tab-row buf)
  ;; the tabs as ui/tabs takes them, each with its count and its hand key
  (let* ((t (todo--detail-task buf))
         (tab (todo--detail-tab buf))
         (count (lambda (name)
                  (cond ((not t) "")
                        ((equal? name "children") (string-append " " (number->string (length (todo--detail-children t)))))
                        ((equal? name "log") (string-append " " (number->string (length (or (plist-get t 'log) '())))))
                        (else "")))))
    (tab-bars-keyed 'detail
      (map (lambda (e) (list (string-append "todo-detail-tab-" (car e))
                             (string-append (cadr e) (count (car e)))
                             (equal? (car e) tab)))
           *todo-detail-tabs*))))

(define (todo--detail-actions tab &optional state source)
  ;; the page's actions, each with its key. The state buttons follow the
  ;; state machine: only the moves STATE allows show, named for what they
  ;; do from there. On Children they act on the sub-task at point, whose
  ;; state the bar cannot know, so every move shows.
  (let* ((kids? (equal? tab "children"))
         (can? (lambda (to) (or kids? (not state) (todo-can-move? state to))))
         (move (lambda (to cmd label key . tone)
                 (if (and (can? to) (or kids? (not (equal? state to))))
                     (list (append (list cmd label key) tone))
                     '())))
         (todo-label (cond (kids? "Accept")
                           ((member state *todo-closed*) "Reopen")
                           ((equal? state "review") "Approve")
                           ((equal? state "doing") "Stop")
                           ((equal? state "waiting") "Resume")
                           (else "Accept")))
         (doing-label (if (equal? state "review") "Rework" "Start")))
    (append
      (if kids? (list (list "todo-detail-open-child" "Open" "RET")) '())
      (move "todo" "todo-detail-accept" todo-label "t")
      (move "doing" "todo-detail-start" doing-label "s")
      (move "done" "todo-detail-done" "Done" "d" "good")
      (move "waiting" "todo-detail-wait" "Wait" "W")
      (move "cancelled" "todo-detail-cancel" "Cancel" "x" "bad")
      (move "inbox" "todo-detail-inbox" (if (equal? state "todo") "Unaccept" "To inbox") "i")
      (if (and (not kids?) (string? source) (not (todo--blank? source)))
          (list (list "todo-detail-source" "Source" "o"))
          '())
      (list (list "todo-detail-agent" "Agent" "M-o")
            (list "todo-detail-visit" "File" "e")
            (list "todo-detail-dismiss" "Dismiss" "k")))))

(define (todo--detail-render! buf)
  (let* ((t (todo--detail-task buf))
         (page (and t (todo--detail-blocks t (todo--detail-tab buf))))
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
    (buffer-set-local! buf 'todo-child-lines (if page (caddr page) '()))
    (if page (anchor-set-blocks! buf text (cadr page)) (anchor-clear! buf))
    (unless (minor-mode-on? buf "anchor-mode") (enable-minor-mode! buf "anchor-mode"))
    (anchor-sync! buf)
    ;; the tabs head the window; the arrows step them
    (unless (buffer-local-value 'arrow-keys buf) (buffer-set-local! buf 'arrow-keys #t))
    ;; the header line is cached: a new tab row has to say so, or the old
    ;; active tab stays lit
    (let ((head (list (component 'ui/tabs (list 'class "todo-detail-tabs" 'tabs (todo--detail-tab-row buf))))))
      (unless (equal? head (buffer-local-value 'header-line-blocks buf))
        (buffer-set-local! buf 'header-line-blocks head)
        (dashboard--sync! buf)))
    ;; the page's keys: the same keys bar the list carries
    (buffer-set-local! buf 'footer-line-blocks
      (list (component 'ui/keys-bar
              (list 'main '(("←→" "tab") ("t" "accept") ("i" "inbox") ("d" "done") ("X" "cancel") ("a" "agent") ("g" "refresh") ("w" "watch") ("q" "quit"))))))
    (buffer-set-read-only! buf #t)
    (if t (todo--detail-retitle! buf t) buf)))

;; the sub-task point was on in Children, kept per task: ((TASK-ID . CHILD-ID) ...)
(define (todo--detail-remember-child! buf)
  (when (equal? (todo--detail-tab buf) "children")
    (let ((hit (assv (car (buffer-line-at-point buf)) (or (buffer-local-value 'todo-child-lines buf) '())))
          (id (buffer-local-value 'todo-id buf)))
      (when (and hit id)
        (buffer-set-local! buf 'todo-child-at
          (cons (cons id (cdr hit))
                (alist-delete (or (buffer-local-value 'todo-child-at buf) '()) id)))))))

(define (todo--detail-tab-set! buf name)
  (todo--detail-remember-child! buf)
  (buffer-set-local! buf 'todo-tab name)
  (todo--detail-render! buf)
  ;; Children opens on the sub-task last lit there, else on its first row,
  ;; so RET opens it at once
  (let* ((lines (or (buffer-local-value 'todo-child-lines buf) '()))
         (last (let ((e (assoc (buffer-local-value 'todo-id buf) (or (buffer-local-value 'todo-child-at buf) '()))))
                 (and e (find (lambda (l) (equal? (cdr l) (cdr e))) lines)))))
    (buffer-goto-line! buf (cond ((not (equal? name "children")) 1)
                                 (last (car last))
                                 ((pair? lines) (apply min (map car lines)))
                                 (else 1))))
  ;; the part point stands in is the lit one
  (anchor-sync! buf))

(define (todo--detail-tab-step! buf step)
  (let* ((names (map car *todo-detail-tabs*))
         (i (let loop ((ns names) (i 0)) (cond ((null? ns) 0) ((equal? (car ns) (todo--detail-tab buf)) i) (else (loop (cdr ns) (+ i 1))))))
         (n (length names)))
    (todo--detail-tab-set! buf (list-ref names (modulo (+ i step n) n)))))

(define (todo--detail-target buf)
  ;; on Children, the sub-task on point's row; elsewhere the page's task
  (if (equal? (todo--detail-tab buf) "children")
      (let ((hit (assv (car (buffer-line-at-point buf)) (or (buffer-local-value 'todo-child-lines buf) '()))))
        (and hit (todo-get (cdr hit))))
      (todo--detail-task buf)))

(define (todo--detail-set! k v)
  (let* ((buf (current-buffer)) (t (todo--detail-target buf)))
    (if t
        (when (todo--set-one! t k v todo-user)
          (todo--detail-render! buf)
          (message (string-append (plist-get t 'title) ": " v)))
        (message "No sub-task at point"))))

;; the page wears its task's title; when a buffer already has that name, such
;; as the task's own chat, it adds " · todo". Answers the name it has now.
(define (todo--detail-retitle! buf t)
  (let ((title (string-trim (or (plist-get t 'title) ""))))
    (cond ((or (equal? title "") (equal? buf title) (equal? buf (string-append title " · todo"))) buf)
          ((rename-buffer! buf title) title)
          ((rename-buffer! buf (string-append title " · todo")) (string-append title " · todo"))
          (else buf))))

(define (todo-show-detail! id)
  (let ((buf (todo--group-buffer "todo-detail-mode" *todo-detail-buffer* (todo--detail-group))))
    (buffer-set-local! buf 'todo-id id)
    (let ((buf (todo--detail-render! buf)))
      (display-buffer-detail! buf (todo--group-list (buffer-group buf)))
      buf)))
;; highlighting a row also brings up its chat, where chats live, without
;; taking focus: the pane already showing a chat, else a spare window, else
;; a split under the task's page


(define-command "todo-show" "Show the task as its own page beside the list"
  (lambda ()
    (let ((t (todo--at)))
      (if t (todo-show-detail! (plist-get t 'id)) (message "No task at point"))))
  'modes '(todo-mode))

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
            (else (group-read-or-create! "Start an agent in group: " start!)))))
  'modes '(todo-detail-mode))

(define-command "todo-detail-source" "Open the task's source beside it: its page, the issue, the link"
  (lambda ()
    (let* ((t (todo--detail-task (current-buffer)))
           (src (and t (plist-get t 'source))))
      (cond ((not t) (message "The task is gone"))
            ((todo--blank? src) (message "This task has no source"))
            ((not (todo-source-open! src)) (message (string-append "Nothing opens " src))))))
  'modes '(todo-detail-mode))

(define-command "todo-detail-visit" "Open the task's file at its heading"
  (lambda ()
    (let ((t (todo--detail-task (current-buffer))))
      (if t
          (begin (visit (plist-get t 'file)) (goto-char! (plist-get t 'pos)))
          (message "The task is gone"))))
  'modes '(todo-detail-mode))

(define-command "todo-detail-refresh" "Read the task again"
  (lambda () (todo--detail-render! (current-buffer)))
  'modes '(todo-detail-mode))

(define-command "todo-detail-tab-overview" "Show the task's status, notes and details"
  (lambda () (todo--detail-tab-set! (current-buffer) "overview"))
  'modes '(todo-detail-mode))

(define-command "todo-detail-tab-children" "Show the task's sub-tasks"
  (lambda () (todo--detail-tab-set! (current-buffer) "children"))
  'modes '(todo-detail-mode))

(define-command "todo-detail-tab-log" "Show the task's log"
  (lambda () (todo--detail-tab-set! (current-buffer) "log"))
  'modes '(todo-detail-mode))

(define-command "todo-detail-tab-next" "Show the next tab of the task: overview, children, log"
  (lambda () (todo--detail-tab-step! (current-buffer) 1))
  'modes '(todo-detail-mode))

(define-command "todo-detail-tab-prev" "Show the previous tab of the task"
  (lambda () (todo--detail-tab-step! (current-buffer) -1))
  'modes '(todo-detail-mode))

(define-command "todo-detail-open-child" "Show the sub-task at point as its own page"
  (lambda ()
    (let ((t (todo--detail-target (current-buffer))))
      (if (and t (equal? (todo--detail-tab (current-buffer)) "children"))
          (begin (todo--detail-remember-child! (current-buffer))
                 (buffer-set-local! (current-buffer) 'todo-id (plist-get t 'id))
                 (todo--detail-tab-set! (current-buffer) "overview"))
          (message "No sub-task at point"))))
  'modes '(todo-detail-mode))

(define-command "todo-detail-parent" "Show the task this one is a sub-task of"
  (lambda ()
    (let* ((t (todo--detail-task (current-buffer))) (p (and t (plist-get t 'parent))))
      (if p
          (begin (buffer-set-local! (current-buffer) 'todo-id p)
                 (todo--detail-tab-set! (current-buffer) "children"))
          (message "This task has no parent"))))
  'modes '(todo-detail-mode))

(define-command "todo-detail-accept" "Mark the task todo: triage it, approve it from review, or reopen it; on Children, the sub-task at point"
  (lambda () (todo--detail-set! 'state "todo"))
  'modes '(todo-detail-mode))

(define-command "todo-detail-done" "Mark the task done; on Children, the sub-task at point"
  (lambda () (todo--detail-set! 'state "done"))
  'modes '(todo-detail-mode))

(define-command "todo-detail-cancel" "Cancel the task; on Children, the sub-task at point"
  (lambda () (todo--detail-set! 'state "cancelled"))
  'modes '(todo-detail-mode))

(define-command "todo-detail-wait" "Park the task as waiting; on Children, the sub-task at point"
  (lambda () (todo--detail-set! 'state "waiting"))
  'modes '(todo-detail-mode))

(define-command "todo-detail-start" "Start the task: in progress, and open its chat; on Children, the sub-task at point"
  (lambda ()
    (let ((t (todo--detail-target (current-buffer))))
      (todo--detail-set! 'state "doing")
      (when t (todo--start-chat! (todo-get (plist-get t 'id)) (current-buffer)))))
  'modes '(todo-detail-mode))

(define-command "todo-detail-inbox" "Send the task back to the inbox, to triage again; on Children, the sub-task at point"
  (lambda () (todo--detail-set! 'state "inbox"))
  'modes '(todo-detail-mode))

(define (todo--detail-with buf f)
  ;; F on the page's task, or on Children the sub-task at point; then redraw
  (let ((t (todo--detail-target buf)))
    (if t
        (begin (f t) (todo--detail-render! buf))
        (message "No sub-task at point"))))

(define (todo--detail-ask! prompt k)
  (let ((buf (current-buffer)))
    (if (todo--detail-target buf)
        (read-string prompt
          (lambda (s) (todo--detail-with buf (lambda (t) (todo-update (plist-get t 'id) (list k s 'by todo-user))))))
        (message "No sub-task at point"))))

(define-command "todo-detail-set-deadline" "Set the task's deadline: YYYY-MM-DD, today, tomorrow, +3d, 2w; on Children, the sub-task at point"
  (lambda () (todo--detail-ask! "Deadline: " 'deadline))
  'modes '(todo-detail-mode))

(define-command "todo-detail-add-note" "Add a note to the task; on Children, the sub-task at point"
  (lambda () (todo--detail-ask! "Note: " 'note))
  'modes '(todo-detail-mode))

(define-command "todo-detail-set-project" "Move the task to another project; a new name makes a new project. On Children, the sub-task at point"
  (lambda ()
    (let* ((buf (current-buffer)) (t (todo--detail-target buf)))
      (if t
          (completing-read "Project: " (todo-projects)
            (lambda (s) (todo--detail-with buf (lambda (t) (todo-update (plist-get t 'id) (list 'project s 'by todo-user)))))
            'default (or (plist-get t 'project) ""))
          (message "No sub-task at point"))))
  'modes '(todo-detail-mode))

(define-command "todo-detail-cycle-priority" "Cycle the task's priority: A, B, C, none; on Children, the sub-task at point"
  (lambda ()
    (todo--detail-with (current-buffer)
      (lambda (t)
        (let ((p (plist-get t 'priority)))
          (todo-update (plist-get t 'id)
                       (list 'priority (cond ((not p) "A") ((equal? p "A") "B") ((equal? p "B") "C") (else #f)) 'by todo-user))))))
  'modes '(todo-detail-mode))

(define-command "todo-detail-toggle-urgent" "Mark the task time-sensitive, or not; on Children, the sub-task at point"
  (lambda ()
    (todo--detail-with (current-buffer)
      (lambda (t) (todo-update (plist-get t 'id) (list 'urgent (not (plist-get t 'urgent)) 'by todo-user)))))
  'modes '(todo-detail-mode))

(define (todo--detail-setup!)
  ;; left and right step the tabs; anchor-mode's map sits in front of ours
  (local-remap! "anchor-right" "todo-detail-tab-next")
  (local-remap! "anchor-left" "todo-detail-tab-prev")
  (desktop-skip! (current-buffer) 'header-line-blocks)
  (desktop-skip! (current-buffer) 'render-blocks)
  (desktop-skip! (current-buffer) 'footer-line-blocks)
  (todo--detail-render! (current-buffer)))

(define-mode "todo-detail-mode" todo--detail-setup!)
(mode-put! "todo-detail-mode" 'chat-subject "todos")
(mode-put! "todo-detail-mode" 'agent-chat
  (lambda (buf) (let ((t (todo--detail-task buf))) (and t (todo--chat-of t)))))

;; the gutter would count the text's lines, not the tasks, so the list and
;; the page draw none
(define (todo--no-line-numbers!) (buffer-set-local! (current-buffer) 'line-numbers "off"))
(add-hook! 'todo-mode-hook 'todo--no-line-numbers!)
(add-hook! 'todo-detail-mode-hook 'todo--no-line-numbers!)

(mode-keys! "todo-detail-mode"
  '(("M-o" "todo-detail-agent")
    ("e" "todo-detail-visit")
    ("o" "todo-detail-source")
    ("g" "todo-detail-refresh")
    ("<right>" "todo-detail-tab-next")
    ("<left>" "todo-detail-tab-prev")
    ("RET" "todo-detail-open-child")
    ("u" "todo-detail-parent")
    ("+" "todo-detail-new-subtask")
    ("t" "todo-detail-accept")
    ("d" "todo-detail-done")
    ("x" "todo-detail-cancel")
    ("D" "todo-detail-set-deadline")
    ("P" "todo-detail-set-project")
    ("N" "todo-detail-add-note")
    ("!" "todo-detail-cycle-priority")
    ("T" "todo-detail-toggle-urgent")
    ("W" "todo-detail-wait")
    ("s" "todo-detail-start")
    ("i" "todo-detail-inbox")
    ("k" "todo-dismiss")
    ("q" "quit-window")))

;; the tabs: 6, 7 and 8 take one, as on every detail page
(tab-bars-declare! "todo-detail-mode"
  (lambda (buf) (list (list "Task" (todo--detail-tab-row buf)))))

;; / on a task's page filters the list, as it does on the list
(define-command "todo-detail-filter" "Search the todo list from a task's page, as / does on the list"
  (lambda ()
    (let ((buf (todo--list-buffer)))
      (if buf (with-current-buffer buf (lambda () (list-filter-live!))) (message "No todo list open"))))
  'modes '(todo-detail-mode))
(define-key (mode-keymap "todo-detail-mode") "/" "todo-detail-filter")

(mode-doc! "todo-detail-mode"
  "One task as its own page, in three tabs: Overview (status, notes, details), Children (the sub-tasks) and Log. Left and right step the tabs, and 6, 7 and 8 take one. `t` accepts, approves or reopens, `i` sends back to the inbox, `s` starts, `d` closes, `x` cancels and `W` parks the task, `D` sets a deadline, `P` moves it to a project, `N` adds a note, `!` cycles the priority and `T` marks it urgent or not, the same keys as the list; the buttons show only the moves the task's state allows; on Children they act on the sub-task at point, `RET` opens it, and `u` goes back up to the parent; `+` files a new sub-task under this task. `M-o` goes to that chat, the one fixing the task, not the one that filed it, and starts one in the group you are in when none is live. A task has one chat. `o` opens its source beside it (its page, the issue, the link), `e` opens the task's file, `g` reads it again, `k` dismisses the task: this page and its chats close, the state stays; `q` puts it away.")

(define (todo-spawn-chat! id group)
  "(todo-spawn-chat! ID GROUP) — hand task ID to a new chat in GROUP. File the task first with todo-create: a short title, the spec in 'notes. Nothing is shown and the focus stays: the task is the marker that comes back to the user in review. Return (ID CHAT)"
  (let* ((g (or (group-resolve-id group) (group-ensure-record! group)))
         ;; asleep or archived, the group's chat is still its chat
         (first? (let ((r (group-record-by-id g))) (not (and r (group-record-primary-chat-id r)))))
         (chat (todo-assign-chat! id g)))
    ;; a group made here has no chat yet: this one becomes its chat pane
    (when first? (group-record-update! g 'primary-chat-id (chat-stable-id! chat)))
    (list id chat)))

(public! 'todo-spawn-chat! "(todo-spawn-chat! ID GROUP) — hand an existing task to a new chat in GROUP without showing it; answers (ID CHAT)")

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
            (else (assign-one! here)))))
  'modes '(todo-mode))



;; a card follows its chat: an event on a chat topic redraws the list
;; when a window shows it, and marks it dirty when none does. A card shows
;; only the status, the stop reason and the minute of the chat-status row,
;; so an event that leaves those the same redraws nothing. Streamed text is
;; most chat events, and one redraw of a long list costs about 500 ms of :ui.
(define *todo-chat-sigs* (if (boundp '*todo-chat-sigs*) *todo-chat-sigs* '()))

(define (todo--chat-sig topic)
  (let ((row (event-view-get 'chat-status topic)))
    (and row (list (plist-get row 'status) (plist-get row 'stop-reason)
                   (and (plist-get row 'at) (format-time (plist-get row 'at) "%H:%M"))))))

(define (todo--chat-changed? topic)
  "#t when the card text of TOPIC's chat changes, and records the new text"
  (let ((sig (todo--chat-sig topic))
        (old (assoc topic *todo-chat-sigs*)))
    (if (and old (equal? (cadr old) sig))
        #f
        (begin
          (set! *todo-chat-sigs*
                (cons (list topic sig) (filter (lambda (s) (not (equal? (car s) topic))) *todo-chat-sigs*)))
          #t))))

;; A chat's state on the cards redraws a shown list at most once in this
;; many ms. Busy agents change state every few seconds, and each redraw of
;; a few hundred cards holds the UI lane for half a second or more.
(define todo-cards-redraw-every-ms 10000)

;; ((BUF (LAST-MS PENDING?)) ...), as alist-put keeps it
(define *todo-cards-redraws* '())

(define (todo--cards-redraw-soon! b)
  (let* ((e (assoc b *todo-cards-redraws*))
         (last (if e (car (cadr e)) 0))
         (pending (and e (cadr (cadr e)))))
    (unless pending
      (let ((wait (max 250 (- (+ last todo-cards-redraw-every-ms) (monotonic-ms)))))
        (set! *todo-cards-redraws* (alist-put *todo-cards-redraws* b (list last #t)))
        (debounce! (string->symbol (string-append "todo-cards:" b)) wait
          (lambda (_)
            (set! *todo-cards-redraws* (alist-put *todo-cards-redraws* b (list (monotonic-ms) #f)))
            (when (buffer-exists? b) (list-redraw! b)))
          #f)))))

(define (todo--on-chat-event e)
  (when (todo--chat-changed? (plist-get e 'topic))
    (for-each (lambda (b)
                (if (window-showing b)
                    (todo--cards-redraw-soon! b)
                    (buffer-mark-dirty! b 'todo-cards)))
              (todo--buffers))))

(define (todo--on-refresh! b keys)
  (cond ((memq 'todo-list keys) (list-refresh! b))
        ((memq 'todo-cards keys) (list-redraw! b))
        ((memq 'todo-detail keys) (todo--detail-render! b))))

(event-subscribe! "todo-cards" "chat:*" 'todo--on-chat-event)
(add-hook! 'buffer-refresh-hook 'todo--on-refresh!)
(add-hook! 'after-save-hook 'todo--after-save!)
(add-hook! 'fs-change-hook 'todo--fs-change)

(define-command "todo-set-deadline" "Set the task's deadline: YYYY-MM-DD, today, tomorrow, +3d, 2w"
  (lambda () (todo--ask-at! "Deadline: " 'deadline))
  'modes '(todo-mode))
(define-command "todo-set-project" "Move the task, or the marked tasks, to another project; a new name makes a new project"
  (lambda ()
    (let ((t (todo--at)))
      (if (or t (pair? (todo--marked-tasks)))
          (completing-read "Project: " (todo-projects)
            (lambda (s)
              (todo--with-tasks (string-append "Move to " s ":")
                (lambda (t) (todo-update (plist-get t 'id) (list 'project s)))))
            'default (or (and t (plist-get t 'project)) ""))
          (message "No task at point"))))
  'modes '(todo-mode))
(define-command "todo-add-note" "Add a note to the task"
  (lambda () (todo--ask-at! "Note: " 'note))
  'modes '(todo-mode))

;; show CHAT in the chat pane, else in the pane beside OWNER; the focus stays
(define (todo--show-chat-beside! chat owner)
  (let ((pane (window-showing-mode "chat-mode" #f)))
    (cond ((window-showing chat) #t)
          (pane (display-buffer-in-window! pane chat))
          (else (panes-display-beside! chat owner)))
    chat))

(define (todo--file-new! title group)
  (let ((id (todo-create title (list 'state "todo" 'group group))))
    (todo--refresh-all!)
    ;; the list where you are, the page beside it
    (run-command "todo")
    (todo-show-detail! id)
    (message (string-append "Filed " id " in " (group-display-name group) "; s starts it"))))

;; C-RET in the New Todo prompt: confirm the title, then ask for the group.
(define todo--new-open? #f)
(define todo--new-pick-group? #f)

(define-command "todo-new-pick-group" "In the New Todo prompt, file the title in a group you choose"
  (lambda ()
    (set! todo--new-pick-group? todo--new-open?)
    (minibuffer-confirm-input!)))

(define-key "minibuffer-mode-map" "C-RET" "todo-new-pick-group")

(define-command "todo-new" "File a new task, then show the list and the task's page beside it; RET files it in this group, C-RET asks for the group first; s starts it and opens its chat"
  (lambda ()
    (set! todo--new-open? #t)
    (set! todo--new-pick-group? #f)
    (minibuffer-read* (string-append "New Todo (" (key-symbol "C-RET") " to set group): ") '()
      (list
        (list 'confirm
          (lambda (title)
            (let ((pick? todo--new-pick-group?)
                  (here (todo--origin-group todo-user)))
              (set! todo--new-open? #f)
              (set! todo--new-pick-group? #f)
              (cond
                ((equal? title "") (message "No title; nothing filed"))
                (pick?
                  (completing-read (string-append "Group for \"" title "\": ") (group-names)
                    (lambda (g) (todo--file-new! title (or (group-resolve-id g) g)))
                    'default (group-display-name here) 'require-match #t))
                (else (todo--file-new! title here))))))
        (list 'cancel (lambda () (set! todo--new-open? #f) (set! todo--new-pick-group? #f)))
        (list 'style #f)))))

;; C-x t is the list; C-x C-t is the todo keys (Cmd-K t and Cmd-K C-t in vscode mode)
(define-prefix-command "todo-prefix-map")
(define-key "todo-prefix-map" "n" "todo-new")
(define-key "todo-prefix-map" "t" "todo")
(define-key "ctl-x-map" "t" "todo")
(define-key "ctl-x-map" "C-t" '(keymap "todo-prefix-map"))
;; filing a task is for every buffer, not just the todo list
(app-entry! "todo-new")

(define (todo--new-subtask! parent after)
  "ask for a title and file it as a sub-task of PARENT, in its group and project; AFTER runs once it is filed"
  (read-string (string-append "Sub-task of " (plist-get parent 'title) ": ")
    (lambda (s)
      (let ((id (todo-create s (list 'state "todo"
                                     'parent (plist-get parent 'id)
                                     'group (plist-get parent 'group)
                                     'project (plist-get parent 'project)
                                     'by todo-user))))
        (todo--refresh-all!)
        (when after (after))
        (message (string-append "Filed sub-task " id))))))

(define-command "todo-new-subtask" "File a new sub-task under the task at point"
  (lambda ()
    (let ((t (todo--at)))
      (if t (todo--new-subtask! t #f) (message "No task at point"))))
  'modes '(todo-mode))

(define-command "todo-detail-new-subtask" "File a new sub-task under this task"
  (lambda ()
    (let* ((buf (current-buffer)) (t (todo--detail-task buf)))
      (if t
          (todo--new-subtask! t (lambda ()
                                  (todo--detail-tab-set! buf "children")))
          (message "The task is gone"))))
  'modes '(todo-detail-mode))

;; a chat files its own card: the task is the chat's, in doing, so the
;; board can tell a chat that finished from one that stopped halfway
(define (todo--ask-update! chat id)
  "ask CHAT's agent to bring task ID up to date from the chat: notes, status and log"
  (agent-continue! chat
    (string-append "Bring task " id " up to date from this chat. "
      "When its goal is blank, set it, one line that says what is true when it is done, with (todo-update \"" id "\" (list 'goal TEXT 'by WHO)). "
      "Add each finding the work must keep with (todo-update \"" id "\" (list 'note TEXT 'by WHO)). "
      "Replace its status with (todo-update \"" id "\" (list 'status TEXT 'by WHO)): Done: and Left:, a few plain lines each. "
      "Record the progress since the last log line with (todo-log \"" id "\" TEXT WHO). "
      "WHO is agent: and your agent id. Change nothing else.")))

(define (todo--chat-tasks chat)
  ;; the tasks CHAT works, as assignee or attached: open ones, else any
  (let* ((who (chat-stable-id! chat))
         (mine (lambda (ts) (filter (lambda (t) (member who (todo-chats t))) ts)))
         (open (mine (todo-list))))
    (if (pair? open) open (mine (todo-list (list 'all #t))))))

(define (todo--goal-text status why)
  ;; the verdict the turn summary gave the chat's goal, with its reason
  (let ((s (if (symbol? status) (symbol->string status) status)))
    (if (todo--blank? why) s (string-append s " - " why))))

(define (todo--goal t)
  ;; the newest verdict on the goal of the chat working T, while it is live
  (let ((c (todo--chat-of t)))
    (or (and (string? c) (buffer-exists? c)
             (let ((s (buffer-local-value 'chat-goal-status c)))
               (and s (todo--goal-text s (buffer-local-value 'chat-goal-why c)))))
        "")))

(define (todo--on-chat-status! buf status why)
  ;; a judged turn leaves one log line on each open task the chat is
  ;; assigned, so the task file says where the work stands; the same
  ;; verdict twice in a row is logged once
  (when todo-turn-log
    (report-errors "todo-turn-log"
      (lambda ()
        (let ((line (string-append "turn: " (todo--goal-text status why))))
          (for-each
            (lambda (t)
              (let ((logs (or (plist-get t 'log) '())))
                (unless (and (pair? logs) (string-suffix? line (car (reverse logs))))
                  (todo-update (plist-get t 'id) (list 'log line 'by "summary")))))
            (todo-list (list 'assignee (chat-stable-id! buf)))))))))

(add-hook! 'chat-status-hook 'todo--on-chat-status!)

(define (todo--show-chat-task! chat)
  "show the task CHAT works as its own page; with several, ask which"
  (let ((ts (todo--chat-tasks chat)))
    (cond ((null? ts) (message "This chat holds no task; C-c t files one"))
          ((null? (cdr ts)) (todo-show-detail! (plist-get (car ts) 'id)))
          (else
            (let ((labels (map (lambda (t) (list (string-append (plist-get t 'id) "  " (plist-get t 'title)) (plist-get t 'id))) ts)))
              (minibuffer-read* "Task: " (map car labels)
                (list (list 'confirm (lambda (l) (let ((hit (assoc l labels))) (when hit (todo-show-detail! (cadr hit)))))))))))))

(define-command "chat-todo" "This chat's task: show its page, and have the chat's agent bring the task up to date. A chat with no task asks to file one: assigned to the chat, in doing; a blank title takes the chat's title, with its running summary as the notes"
  (lambda ()
    (let* ((chat (current-buffer))
           (who (and (chat-buffer? chat) (chat-stable-id! chat)))
           (held (and who (todo-list (list 'assignee who)))))
      (cond ((not who) (message "Not a chat"))
            ((pair? held)
             (let ((id (plist-get (car held) 'id)))
               (todo--show-chat-task! chat)
               (todo--ask-update! chat id)
               (message (string-append "Updating " id " from this chat"))))
            (else
             (y-or-n "Create a todo for this chat? "
               (lambda ()
                 (read-string "Task (blank: from the chat): "
                   (lambda (s)
                     (let* ((blank? (todo--blank? s))
                            (title (if blank? (chat-title-of chat) s))
                            (summary (buffer-local-value 'chat-summary chat))
                            (g (buffer-group chat))
                            (name (and g (group-name g)))
                            (id (todo-create title (append (list 'project (if (member name (todo-projects)) name todo-default-project)
                                                                 'state "doing" 'assignee who 'group g)
                                                           (if (and blank? (string? summary) (not (todo--blank? summary)))
                                                               (list 'notes summary)
                                                               '())))))
                       (todo--refresh-all!)
                       (todo--ask-update! chat id)
                       (message (string-append "Filed " id ": " title))))
                   'initial chat)))))))
  'modes '(chat-mode))

(define (todo--view-set! buf name)
  (todo--state-drop! buf)
  (list-tab-set! buf name)
  (list-refresh! buf))

(define (todo--view-step! buf step)
  (todo--state-drop! buf)
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
;; The counts read only the tasks, the group and project filters, the user
;; and the day. Every chat turn redraws the list, and nine views times every
;; task cost 120 ms of :ui, so one count keeps its answer for the same input.
(define *todo-tab-counts* #f)

(define (todo--tab-counts buf all)
  ;; every tab counts what it would show under the list's facets and the
  ;; text typed after /, so the counts move as you type
  (let* ((fs (filter (lambda (f) (member (car f) '("group" "project" "state"))) (list-filters buf)))
         (q (list-query buf))
         (key (list all fs q todo-user (todo--today)))
         (hit *todo-tab-counts*))
    (if (and hit (equal? (car hit) key))
        (cadr hit)
        (let* ((scoped (filter (lambda (t) (and (null? (remove (lambda (f) (todo--filter buf t f)) fs))
                                                (or (equal? q "") (todo--match buf t q))))
                               all))
               (counts (map (lambda (v) (todo--tab-count all scoped v)) *todo-views*)))
          (set! *todo-tab-counts* (list key counts))
          counts))))

(define (todo--tab-blocks buf)
  (let* ((all (todo--all))
         (counts (todo--tab-counts buf all))
         (view (todo--view buf)))
    (list (component 'ui/tabs
            (list 'class "todo-tabs"
                  'tabs (let loop ((vs *todo-views*) (cs counts) (out '()))
                          (if (null? vs)
                              (reverse out)
                              (loop (cdr vs) (cdr cs)
                                    (cons (list (string-append "todo-tab-" (car (car vs)))
                                                (string-append (car (car vs)) " " (number->string (car cs)))
                                                (equal? (car (car vs)) view))
                                          out)))))))))

;; a click on a sub-task row of a task page visits it, as RET does
(add-hook! (list 'block-click 'todo-child)
  (lambda (buf id)
    (and (string? id)
         (string-prefix? "todo-child:" id)
         (buffer-exists? buf)
         (let ((t (todo-get (substring id 11 (string-length id)))))
           (and t
                (begin (todo--detail-remember-child! buf)
                       (buffer-set-local! buf 'todo-id (plist-get t 'id))
                       (todo--detail-tab-set! buf "overview")
                       #t))))))

(define-style! 'todo-child "
.todo-child { display: flex; gap: 12px; align-items: baseline; cursor: pointer; }
.todo-child-title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.todo-child-state { flex: none; font-size: .85em; }
")

(add-hook! (list 'block-click 'todo-tabs)
  (lambda (buf id)
    (and (string? id)
         (string-prefix? "todo-tab-" id)
         (buffer-exists? buf)
         (let ((name (substring id 9 (string-length id))))
           (and (assoc name *todo-views*)
                (begin (todo--view-set! buf name) #t))))))

(define-command "todo-next-view" "Show the next status tab: open, inbox, waiting, closed, all"
  (lambda () (todo--view-step! (todo--list-buffer) 1))
  'modes '(todo-mode))

(define-command "todo-prev-view" "Show the previous status tab"
  (lambda () (todo--view-step! (todo--list-buffer) -1))
  'modes '(todo-mode))

(define-command "todo-filter-project" "Show one project's tasks: pick it from the list; all shows every project"
  (lambda ()
    (let ((buf (todo--list-buffer)))
      (completing-read "Project: " (cons "all" (todo-projects))
        (lambda (p)
          (list-facet-set! buf (list-facet buf "project") (if (member p '("" "all")) #f p)))
        'default "all")))
  'modes '(todo-mode))

;; f is the filter prefix, as / is in Emacs ibuffer: each filter stacks on
;; the ones before it, f ! negates the newest, f | ors the two newest, \\
;; pops one and f / drops them all. / stays the text search.
(define-keymap! "todo-filter-map")

(define (todo--filter-add! buf f)
  (list-filter-push! buf f)
  (list-goto-first-entry buf)
  (message (string-append "Filter: " (list-filters-text buf))))

;; one filter as the list's filter line names it
(define (todo--filter-text-of buf f)
  (let ((saved (list-filters buf)))
    (buffer-set-local! buf 'list-filters (list f))
    (let ((s (list-filters-text buf)))
      (buffer-set-local! buf 'list-filters saved)
      s)))

(define (todo--filter-values buf key)
  (let loop ((ts (todo-list (todo--view-spec buf))) (out '()))
    (if (null? ts) (sort out)
        (let* ((v (plist-get (car ts) key))
               (vs (if (list? v) v (list v))))
          (loop (cdr ts)
                (fold (lambda (acc x) (if (and (string? x) (not (equal? x "")) (not (member x acc))) (cons x acc) acc))
                      out vs))))))

(define (todo--filter-read! prompt key kind)
  (let* ((buf (todo--list-buffer))
         (here (let ((t (todo--at))) (and t (plist-get t key))))
         (here (if (list? here) (and (pair? here) (car here)) here)))
    (completing-read prompt (todo--filter-values buf key)
      (lambda (v) (when (and (string? v) (not (equal? v ""))) (todo--filter-add! buf (list kind v))))
      'default (if (string? here) here ""))))

(define (todo--filter-text! prompt kind)
  (let ((buf (todo--list-buffer)))
    (completing-read prompt '()
      (lambda (v) (when (and (string? v) (not (equal? v ""))) (todo--filter-add! buf (list kind v)))))))

(define-command "todo-filter-by-group" "Keep the tasks of one group"
  (lambda ()
    (let* ((buf (todo--list-buffer))
           (names (map (lambda (g) (list (or (group-name g) g) g)) (todo--filter-values buf 'group)))
           (here (let ((t (todo--at))) (and t (plist-get t 'group)))))
      (completing-read "Filter by group: " (map car names)
        (lambda (n) (let ((hit (assoc n names)))
                      (when hit (todo--filter-add! buf (list "group" (cadr hit))))))
        'default (if (string? here) (or (group-name here) "") ""))))
  'modes '(todo-mode))
(define-command "todo-filter-by-project" "Keep the tasks of one project"
  (lambda () (todo--filter-read! "Filter by project: " 'project "project")) 'modes '(todo-mode))
(define-command "todo-filter-by-state" "Keep the tasks in one state"
  (lambda () (todo--filter-read! "Filter by state: " 'state "state")) 'modes '(todo-mode))
(define-command "todo-filter-by-assignee" "Keep the tasks of one assignee"
  (lambda () (todo--filter-read! "Filter by assignee: " 'assignee "assignee")) 'modes '(todo-mode))
(define-command "todo-filter-by-tag" "Keep the tasks with one tag"
  (lambda () (todo--filter-read! "Filter by tag: " 'tags "tag")) 'modes '(todo-mode))
(define-command "todo-filter-by-priority" "Keep the tasks of one priority"
  (lambda () (todo--filter-read! "Filter by priority: " 'priority "priority")) 'modes '(todo-mode))
(define-command "todo-filter-by-title" "Keep the tasks whose title has the text"
  (lambda () (todo--filter-text! "Filter by title: " "title")) 'modes '(todo-mode))
(define-command "todo-filter-by-content" "Keep the tasks whose title or notes have the text"
  (lambda () (todo--filter-text! "Filter by content: " "content")) 'modes '(todo-mode))
(define-command "todo-negate-filter" "Turn the newest filter into its opposite"
  (lambda ()
    (let* ((buf (todo--list-buffer)) (fs (list-filters buf)))
      (if (null? fs) (message "no filter")
          (begin (buffer-set-local! buf 'list-filters (cdr fs))
                 (todo--filter-add! buf (list "not" (todo--filter-text-of buf (car fs)) (car fs)))))))
  'modes '(todo-mode))
(define-command "todo-or-filter" "Join the two newest filters: keep a task either one keeps"
  (lambda ()
    (let* ((buf (todo--list-buffer)) (fs (list-filters buf)))
      (if (< (length fs) 2) (message "or needs two filters")
          (let ((a (cadr fs)) (b (car fs)))
            (buffer-set-local! buf 'list-filters (cddr fs))
            (todo--filter-add! buf (list "or" (string-append (todo--filter-text-of buf a) " | " (todo--filter-text-of buf b)) a b))))))
  'modes '(todo-mode))
(define-command "todo-filter-disable" "Drop every filter"
  (lambda ()
    (let ((buf (todo--list-buffer)))
      (list-filter-clear! buf)
      (list-goto-first-entry buf)
      (message "Filters off")))
  'modes '(todo-mode))

(for-each (lambda (p) (define-key "todo-filter-map" (car p) (cadr p)))
  '(("g" "todo-filter-by-group") ("p" "todo-filter-by-project") ("s" "todo-filter-by-state")
    ("@" "todo-filter-by-assignee") ("#" "todo-filter-by-tag") ("i" "todo-filter-by-priority")
    ("n" "todo-filter-by-title") ("c" "todo-filter-by-content")
    ("!" "todo-negate-filter") ("|" "todo-or-filter") ("t" "list-facets") ("/" "todo-filter-disable")))

(for-each (lambda (p) (command-label! (car p) (cadr p)))
  '(("todo-filter-by-group" "group") ("todo-filter-by-project" "project") ("todo-filter-by-state" "state")
    ("todo-filter-by-assignee" "assignee") ("todo-filter-by-tag" "tag") ("todo-filter-by-priority" "priority")
    ("todo-filter-by-title" "title") ("todo-filter-by-content" "title or notes")
    ("todo-negate-filter" "negate last") ("todo-or-filter" "or last two")
    ("list-facets" "tabs") ("todo-filter-disable" "clear all")))

(define-command "todo-refresh" "Re-read the todo files, and look again for new ones"
  (lambda () (todo--refresh-all!) (todo--rescan!))
  'modes '(todo-mode))

(define-command "todo-next-sort" "Cycle the order: status, urgency, deadline, created, active"
  (lambda ()
    (let* ((buf (todo--list-buffer))
           (next (list-sort-step! buf *todo-sorts* 1 "status")))
      (list-refresh! buf)
      (message (string-append "Todos by " next)))))

;; moving does not open the page, so the highlighted row says RET does
(define-style! 'todo-list ".window[data-buffer^=\"*Todos*\"] c-line.hl-line::after { content: \"\\23CE\"; margin-left: auto; padding: 0 0.6em; opacity: 0.55; }")

;; a, on the list: the moves and edits of the task at point, as a menu
(define (todo--action-groups buf)
  (let* ((t (with-current-buffer buf todo--at))
         (state (and t (plist-get t 'state)))
         (can? (lambda (to) (or (not state) (and (not (equal? state to)) (todo-can-move? state to)))))
         (move (lambda (to key label cmd) (if (can? to) (list (transient-suffix key label cmd)) '())))
         (accept (cond ((member state *todo-closed*) "Reopen")
                       ((equal? state "review") "Approve")
                       ((equal? state "doing") "Stop")
                       ((equal? state "waiting") "Resume")
                       (else "Accept"))))
    (list (cons "State"
                (append (move "todo" "t" accept "todo-accept")
                        (move "doing" "s" (if (equal? state "review") "Rework" "Start, open its chat") "todo-mark-doing")
                        (move "done" "d" "Done" "todo-mark-done")
                        (move "waiting" "W" "Wait" "todo-mark-waiting")
                        (move "cancelled" "x" "Cancel" "todo-mark-cancelled")
                        (move "inbox" "i" "To inbox" "todo-mark-inbox")))
          (list "Task"
                (transient-suffix "D" "Deadline" "todo-set-deadline")
                (transient-suffix "P" "Project" "todo-set-project")
                (transient-suffix "N" "Note" "todo-add-note")
                (transient-suffix "!" "Priority" "todo-cycle-priority")
                (transient-suffix "T" "Urgent, or not" "todo-toggle-urgent")
                (transient-suffix "+" "Sub-task" "todo-new-subtask"))
          (list "Open"
                (transient-suffix "o" "Its chat" "todo-assign")
                (transient-suffix "e" "Its file" "todo-visit")
                (transient-suffix "k" "Dismiss" "todo-dismiss")))))

(transient-define-prefix "todo-actions" "Act on the task at point: change its state, edit it, open its chat or file" todo--action-groups)
(command-modes! "todo-actions" '(todo-mode))

(define-list-mode! "todo-mode"
  (list
    'buffer *todo-buffer*
    'special #f
    ;; moving changes nothing beside the list; RET (todo-show) opens the
    ;; row's page, and chat-follow-modes brings its chat
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
              '(("←→" "status") ("RET" "open") ("a" "actions") ("TAB" "fold") ("t" "accept") ("s" "start") ("i" "inbox") ("d" "done") ("x" "cancel") ("W" "wait")
                ("M-o" "agent") ("c" "capture") ("+" "sub-task") ("/" "search") ("f" "filter") ("<" "group") (">" "sort") ("g" "refresh") ("w" "watch") ("q" "quit")))
    'noun "task"
    ;; the stacked layout has no columns until it draws, so the table's own
    ;; arrow remap misses it at open; the mode states it
    'remap '(("next-line" "list-next") ("previous-line" "list-prev"))
    'keys '(("RET" "todo-show")
            ("TAB" "list-toggle-children")
            ("S-TAB" "list-toggle-all-children")
            ("M-o" "todo-assign")
            ("e" "todo-visit")
            ("t" "todo-accept")
            ("d" "todo-mark-done")
            ("x" "todo-mark-cancelled")
            ("W" "todo-mark-waiting")
            ("s" "todo-mark-doing")
            ("i" "todo-mark-inbox")
            ("N" "todo-add-note")
            ("a" "todo-actions")
            ("c" "todo-new")
            ("+" "todo-new-subtask")
            ("v" "todo-next-view")
            ("<right>" "todo-next-view")
            ("<left>" "todo-prev-view")
            ("F" "todo-filter-project")
            ;; f filters as / does in Emacs ibuffer; / is the text search
            ("f" (keymap "todo-filter-map"))
            (">" "todo-next-sort")
            ("g" "todo-refresh")
            ("k" "todo-dismiss")
            ("q" "quit-window"))
    'doc "The shared todo list from todo-directories, most urgent first: review, then doing, todo, inbox and waiting. `t` accepts a task (triage it, approve it from review, or reopen a done or cancelled one), `i` sends it back to the inbox, `d` closes it, `x` cancels, `W` parks it, `s` starts it. `s` also opens its chat. `M-o` goes to its chat, or hands it to a new chat in a group, `N` adds a note. `a` opens the task's action menu: every move, and the deadline, project, priority and urgent mark, which the task's page also has as `D`, `P`, `!` and `T`. With tasks marked (`SPC`, or `*` for every task the filter shows), `t`, `i`, `d`, `x`, `W`, `s`, `M-o`, `N` and the action menu act on the marked tasks after asking. imenu picks a status tab. `c` files a new task, `+` a sub-task under the task at point. The status tabs, each with its count, head the list: open, inbox, waiting, closed, all; left and right (or `v`) step them, and a click takes one. `>` cycles the order: status, urgency (urgent first), deadline, created (newest first). `<` cycles the sections: none, group, project, status. It opens on the tasks of the group you are in. `/` searches the title, notes, project, state, assignee, tags and id; words narrow further: p:project, g:group, s:state, @assignee, #tag, !priority; on a task's page `/` searches the list too. `f` filters as Emacs ibuffer's `/` does, and the filters stack: `f g` group, `f p` project, `f s` state, `f @` assignee, `f #` tag, `f i` priority, `f n` title, `f c` title or notes, `f !` negates the newest filter, `f |` ors the two newest, `f /` drops them all; `f t` picks Group, Project or Status from tabs. The status tabs count what the filters and the typed text leave. `\\` drops the newest filter. A sub-task sits under its task, indented; `TAB` folds the sub-tasks under a task, and `S-TAB` folds them all or opens them all. `RET` shows the task as its own page; `k` dismisses a task: its page and its chats close, the state stays; `e` opens the task's file."))

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

The user and every agent share one todo list. Each group keeps its tasks in its own folder, groups/<id>/todos.md, under the compos home; the project is a field of the task. Use the todo calls; do not edit those files.

- Read: `(todo-list [SPEC])` gives open tasks, most urgent first. SPEC is a plist: state, project, assignee (\"none\" is unassigned), tag, text, overdue, ready. `(todo-next WHO)`, `(todo-get ID)` and `(todo-projects)` answer the rest.
- File: `(todo-create TITLE PROPS)` gives the new id. PROPS must hold 'group: \"put a todo in X\" means group X, by name or id, not a project and not your own chat's group. Without it the call errors and lists the groups; pick one and call again. A task you find goes in as inbox, for the user to triage.
- Kick off: when the user asks for a todo, file it and start an agent on it in the same turn with `(todo-assign-chat! ID GROUP WHO)`, GROUP being the todo's group. It starts the chat on the group's own backend and sends it the brief. Do not stop at filing, and do not ask whether to start it. When your own chat is clean, that is, the todo request is its first task, do not start a new chat: file the todo with 'assignee `(chat-stable-id! CHAT)` and 'state \"doing\", CHAT being your chat buffer, and work it in this chat.
- Work: `(todo-claim ID WHO)`, then `(todo-done ID RESULT WHO)`, `(todo-wait ID REASON WHO)` or `(todo-review ID SUMMARY WHO)`. `(todo-log ID TEXT WHO)` records progress. RESULT and SUMMARY become the task's status and go to its parent's log by themselves. They are the handover: what is done, where, the numbers, and what is left, complete without the chat. Work after review goes in with `todo-review` again and a new summary, not as a log line.
- The task is the record, never the chat, a side file or a memory; whoever takes it next reads only the task. It has four parts. The goal is one line that says what is true when it is done; set it with `(todo-update ID (list 'goal TEXT 'by WHO))`. Notes are the brief: what to do, why, and the rules; add a finding the work must keep with `(todo-update ID (list 'note TEXT 'by WHO))`. Status is where it stands; replace it with `(todo-update ID (list 'status TEXT 'by WHO))` whenever that changes. Write it for the user first: two parts, `Done:` and `Left:`, each a few short lines in plain words that say what works now and what remains (`Left: nothing` when nothing does). Give the numbers that matter and name the main file or function the next worker needs; leave ids, raw output and step-by-step history to the log. The log is the history; `todo-log` adds to it.
- A chat that coordinates a parent task keeps the parent's status current: when a sub-task goes to review or done, say what it changed for the goal.
- Handover: `(todo-handover! ID WHO)` archives the chat working the task, starts a new chat in the task's group with the task as its brief, and makes it the assignee. Bring the status up to date first: the task is all the new chat gets. A chat that hands over its own task is archived when its turn ends.
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
;;; A task for any list item

;; Any row can carry a task, the way a chat does with chat-todo. A mode
;; says what its row at point is with todo-item-register!: a title, a
;; source key that leads back to the row, and notes. A mode that says
;; nothing still works: the line at point is the title, a file line is its
;; own source, and the buffer's context provider writes the notes.

(domain! 'writing)
(effects! '(read))

(define *todo-item-providers* (if (boundp '*todo-item-providers*) *todo-item-providers* '()))

(define (todo--item-generic buf)
  (let* ((at (buffer-line-at-point buf))
         (line (and at (car at)))
         (text (and at (string-trim (cadr at))))
         (path (buffer-file-name buf))
         (ctx (buffer-context buf)))
    (and (not (todo--blank? text))
         (list 'title (if (> (string-length text) 120) (substring text 0 120) text)
               'source (and path line (string-append "file:" path ":" (number->string line)))
               'notes (string-append "From " buf (if line (string-append ", line " (number->string line)) "")
                                     (if (string? ctx) (string-append ": " ctx) ""))))))

(define (todo-item-at buf)
  "(todo-item-at BUF) — the row at point in BUF as a plist of title, source and notes: its mode's provider, else the line at point; #f on a blank line"
  (let* ((mode (or (buffer-local-value 'mode-name buf) ""))
         (hit (assoc mode *todo-item-providers*)))
    (or (and hit ((cadr hit) buf))
        (todo--item-generic buf))))

(public! 'todo-item-at "(todo-item-at BUF) — the row at point in BUF as a plist of title, source and notes: its mode's provider, else the line at point; #f on a blank line")

(effects! '(write))

(define (todo-item-register! mode fn)
  "(todo-item-register! MODE FN) — the row at point in MODE files as (FN BUF): a plist of title, source and notes, or #f when no row is there"
  (set! *todo-item-providers*
        (cons (list mode fn) (filter (lambda (e) (not (equal? (car e) mode))) *todo-item-providers*)))
  mode)

(public! 'todo-item-register! "(todo-item-register! MODE FN) — the row at point in MODE files as (FN BUF): a plist of title, source and notes, or #f when no row is there")

(define-command "todo-from-item" "File a task for the row at point, with the row as its source; a row that already has an open task shows that task instead"
  (lambda ()
    (let* ((buf (current-buffer))
           (item (todo-item-at buf))
           (source (and item (plist-get item 'source)))
           (held (and source (todo-of-source source))))
      (cond
        ((not item) (message "No item at point"))
        ((and held (not (member (plist-get held 'state) *todo-closed*)))
         (todo-show-detail! (plist-get held 'id))
         (message (string-append "This already has " (plist-get held 'id))))
        (else
          (read-string "Task: "
            (lambda (s)
              (let* ((title (if (todo--blank? s) (plist-get item 'title) s))
                     (notes (plist-get item 'notes))
                     (id (todo-create title
                           (append (list 'state "todo" 'group (todo--origin-group todo-user) 'by todo-user)
                                   (if source (list 'source source) '())
                                   (if (todo--blank? notes) '() (list 'notes notes))))))
                (todo--refresh-all!)
                (todo-show-detail! id)
                (message (string-append "Filed " id ": " title))))
            'initial (plist-get item 'title)))))))

(todo-source-opener-register! "file:"
  (lambda (key)
    (let* ((rest (substring key 5 (string-length key)))
           (i (string-rindex rest ":"))
           (n (and i (string->number (substring rest (+ i 1) (string-length rest)))))
           (path (if n (substring rest 0 i) rest)))
      (with-frame-windows
        (lambda ()
          (let ((b (visit path)))
            (window-set-buffer! (get-other-window) b)
            (when n (buffer-goto-line! b n))))))))

;;; Catalog stamps for the names the docs and skills teach (the effects audit of 2026-11-26).
(domain! 'chat)
(effects! '(write spend))
(public! 'todo-assign-chat! "(todo-assign-chat! ID GROUP [WHO]) — start a chat in GROUP on todo ID")
(effects! '(write))
(public! 'todo-reopen "(todo-reopen ID [REASON WHO]) — open a closed todo again")
