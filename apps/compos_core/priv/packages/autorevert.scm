;;; autorevert.scm --- a file buffer follows its file.
;;;
;;; Something outside the editor writes a file the editor holds open: git
;;; checkout, another session, a formatter, a tool that got past the
;;; permission policy. The buffer keeps the old text and still reports
;;; itself unmodified, so the next save from it puts the old text back and
;;; says nothing. Auto-revert closes that window: when the file differs
;;; and the buffer still holds exactly the text it last agreed with the
;;; file on, the buffer takes the file.
;;;
;;; That remembered text is the test, never the modified flag. Inside
;;; compos a buffer is where code is written and saving is a separate
;;; decision, so buffers carry live unsaved work for hours; and the flag
;;; is the very thing that is wrong here, because a write behind the
;;; editor's back leaves a buffer reading unmodified while it differs.
;;; A buffer that no longer matches its remembered text has work in it
;;; and is never written to, whatever the flag says. That is the case
;;; worth telling the user about.
;;;
;;; The mode is frame-local and on unless a frame turns it off, so one
;;; frame can hold a buffer still while the others follow.

(domain! 'buffers)
(effects! '(write))

(defcustom 'auto-revert-file-buffers #t
  "Follow file changes on disk in a frame that has not decided for itself."
  'group 'buffers 'type 'boolean)

;;; --- the frame-local mode -----------------------------------------------------

;; A frame that never spoke follows the default. "on" and "off" are the
;; only overrides a frame stores.
(define (auto-revert-on? frame)
  (let ((v (frame-local-in frame 'auto-revert)))
    (cond ((equal? v "on") #t)
          ((equal? v "off") #f)
          (else auto-revert-file-buffers))))

(define (auto-revert-any-frame?)
  (let loop ((fs (frame-list)))
    (cond ((null? fs) #f)
          ((auto-revert-on? (car fs)) #t)
          (else (loop (cdr fs))))))

;; A buffer a mode-off frame shows is held still even when another frame
;; would follow it: the frame that turned the mode off is the one looking
;; at it.
(define (auto-revert-held? buf)
  (let loop ((ws (window-list-all)))
    (cond ((null? ws) #f)
          ((and (equal? (cadr (car ws)) buf)
                (not (auto-revert-on? (caddr (car ws)))))
           #t)
          (else (loop (cdr ws))))))

(define (auto-revert-follows? buf)
  (and (auto-revert-any-frame?) (not (auto-revert-held? buf))))

;; set-frame-local! only ever writes the selected frame, and a frame that
;; is not the selected one still has to be able to decide.
(define (auto-revert-set! frame on?)
  (let* ((entry (assoc frame *frame-locals*))
         (locals (if entry (cadr entry) '()))
         (rest (filter (lambda (e) (not (equal? (car e) frame))) *frame-locals*))
         (others (filter (lambda (e) (not (equal? (car e) 'auto-revert))) locals)))
    (set! *frame-locals*
      (cons (list frame (cons (list 'auto-revert (if on? "on" "off")) others))
            rest))))

(define-command "auto-revert-mode" "Follow file changes on disk in this frame, or stop"
  (lambda ()
    (let ((on? (auto-revert-on? (selected-frame))))
      (auto-revert-set! (selected-frame) (not on?))
      (message (if on?
                   "auto-revert off in this frame"
                   "auto-revert on in this frame")))))

;;; --- the roots we watch -------------------------------------------------------

;; Every open file buffer is watched, taken once per place. watch-path! is
;; refcounted, so taking the same place again on every visit would leak
;; references nothing drops.
;;
;; A repository is watched deep, and that one watch covers every file in it.
;; A file outside a repository is watched through its own directory, and
;; shallow: a deep watch on a home directory is the recursive fsevents loop
;; that took the daemon down before, and a loose file needs no more than its
;; own directory anyway.
;; (ASKED DEPTH WATCHED) rows. The watcher answers with the root it really
;; took, which is not always the one asked for: a home directory reached
;; through a symlink comes back under its real name. A buffer remembers the
;; watched name, because that is the name a file event arrives under.
(define *auto-revert-roots* '())

(define (auto-revert-watch! root depth)
  (if (not (string? root))
      #f
      (let ((hit (filter (lambda (e) (and (equal? (car e) root)
                                          (equal? (cadr e) depth)))
                         *auto-revert-roots*)))
        (if (pair? hit)
            (caddr (car hit))
            (let* ((got (if (equal? depth 'deep) (watch-path! root 'deep) (watch-path! root)))
                   (watched (if (string? got) got root)))
              (set! *auto-revert-roots*
                (cons (list root depth watched) *auto-revert-roots*))
              watched)))))

;; git-root answers with an error list outside a repository, and a file
;; buffer is not required to live in one.
(define (auto-revert-buffer-root buf)
  (let* ((path (buffer-path buf))
         (root (and path (git-root (path-directory path)))))
    (and (string? root) root)))

(define (auto-revert-watch-buffer! buf)
  (let ((path (buffer-path buf)))
    (when path
      (let* ((root (auto-revert-buffer-root buf))
             (watched (if root
                          (auto-revert-watch! root 'deep)
                          (auto-revert-watch! (path-directory path) 'shallow))))
        (when (string? watched)
          (buffer-set-local! buf 'auto-revert-root watched))))))

;; Buffers the desktop restored before this package loaded still need
;; their root watched.
(define (auto-revert-watch-open-buffers!)
  (for-each (lambda (b)
              (auto-revert-watch-buffer! b)
              (auto-revert-seed-base! b))
            (buffer-list)))

;; The mark is taken first. Watching is what can fail here, and a file
;; whose root could not be watched must still be one the editor knows it
;; has not touched.
(define (auto-revert-created! buf)
  (when (buffer-path buf)
    (auto-revert-base! buf (buffer-text buf))
    (auto-revert-watch-buffer! buf)))

(define (auto-revert-visited!)
  (auto-revert-created! (current-buffer)))

;;; --- following the file -------------------------------------------------------

;; The text a buffer last agreed with its file on. A buffer still holding
;; it has nothing of its own to lose. Visiting sets it, saving sets it, a
;; revert sets it, and any file event that finds buffer and file equal
;; sets it, so the mark heals itself.
(define (auto-revert-base buf) (buffer-local buf 'auto-revert-base))

(define (auto-revert-base! buf text)
  (buffer-set-local! buf 'auto-revert-base text))

(define (auto-revert-saved!)
  (let ((buf (current-buffer)))
    (when (buffer-path buf) (auto-revert-base! buf (buffer-text buf)))))

;; A buffer open before this package loaded has no mark. Seed it only
;; from agreement: a buffer that already differs from its file may be
;; holding unsaved work, and a guess there writes over it.
(define (auto-revert-seed-base! buf)
  (let* ((path (buffer-path buf))
         (disk (and path (not (auto-revert-base buf)) (read-file path))))
    (when (and (string? disk) (equal? disk (buffer-text buf)))
      (auto-revert-base! buf disk))))

;; A buffer with no mark at all, for a file that has already moved. Two
;; independent records have to agree that nothing was ever typed into it:
;; the edit log, which is provenance and knows an agent's edits, and the
;; modified flag, which is weaker but fails in the other direction. One
;; of them alone is not enough to write over a buffer.
(define (auto-revert-untouched? buf)
  (and (null? (buffer-edit-log buf))
       (not (buffer-modified? buf))))

(define (auto-revert-may-take? buf text)
  (let ((base (auto-revert-base buf)))
    (if (string? base)
        (equal? base text)
        (auto-revert-untouched? buf))))

;;; --- the minimal edit ---------------------------------------------------------

;; A revert that deletes the whole buffer and inserts the file writes every
;; byte of the file, so the weave credits every byte to whoever reverted.
;; Measured on a five line file: attribution went from the 23 bytes actually
;; typed to all 40, crediting the reverting actor with the line git wrote and
;; with three lines nobody in the editor had ever touched.
;;
;; So only the lines that changed are written. An untouched line is not
;; touched, and keeps its author. Spans are lines, never byte arithmetic on
;; strings: line-start-position converts a line to a byte offset exactly,
;; whatever the encoding.

(define auto-revert-resync-window 400)  ; how far ahead to look for a resync
(define auto-revert-resync-run 1)       ; matching lines needed to believe one

(define (auto-revert-drop lst k)
  (if (or (= k 0) (null? lst)) lst (auto-revert-drop (cdr lst) (- k 1))))

(define (auto-revert-take lst k)
  (if (or (= k 0) (null? lst))
      '()
      (cons (car lst) (auto-revert-take (cdr lst) (- k 1)))))

;; Do both sides start with RUN equal lines? Running out on both sides at
;; once counts: the end of a file is a resync.
;;
;; One matching line is enough. The run only chooses where to resume, and a
;; badly chosen resume cannot make the script wrong: the walk consumes both
;; line lists once, in order, so the hunks always rebuild the file exactly.
;; A longer run reads as more careful and is worse, because it steps over a
;; second change that is close to the first and swallows the untouched lines
;; between them. Taking the smallest resync keeps every hunk tight.
(define (auto-revert-run-matches? a b run)
  (cond ((= run 0) #t)
        ((and (null? a) (null? b)) #t)
        ((or (null? a) (null? b)) #f)
        ((equal? (car a) (car b))
         (auto-revert-run-matches? (cdr a) (cdr b) (- run 1)))
        (else #f)))

;; The smallest lookahead that puts the two sides back in step, as
;; (OLD-SKIP NEW-SKIP): lines deleted, lines inserted, or lines changed.
;; #f when nothing inside the window does, and then the rest is one hunk.
(define (auto-revert-resync o n)
  (let loop ((k 1))
    (cond
      ((> k auto-revert-resync-window) #f)
      ((auto-revert-run-matches? (auto-revert-drop o k) n auto-revert-resync-run)
       (list k 0))
      ((auto-revert-run-matches? o (auto-revert-drop n k) auto-revert-resync-run)
       (list 0 k))
      ((auto-revert-run-matches? (auto-revert-drop o k) (auto-revert-drop n k)
                                 auto-revert-resync-run)
       (list k k))
      (else (loop (+ k 1))))))

;; ((FIRST COUNT LINES) ...), oldest first: replace COUNT old lines at
;; 0-based FIRST with LINES.
(define (auto-revert-hunks old new)
  (let loop ((o old) (n new) (i 0) (acc '()))
    (cond
      ((and (null? o) (null? n)) (reverse acc))
      ((null? o) (reverse (cons (list i 0 n) acc)))
      ((null? n) (reverse (cons (list i (length o) '()) acc)))
      ((equal? (car o) (car n)) (loop (cdr o) (cdr n) (+ i 1) acc))
      (else
        (let ((sync (auto-revert-resync o n)))
          (if sync
              (let ((ok (car sync)) (nk (cadr sync)))
                (loop (auto-revert-drop o ok) (auto-revert-drop n nk) (+ i ok)
                      (cons (list i ok (auto-revert-take n nk)) acc)))
              (reverse (cons (list i (length o) n) acc))))))))

(define (auto-revert-line-byte buf k n)
  (if (>= k n)
      (buffer-size buf)
      (with-current-buffer buf (lambda () (line-start-position (+ k 1))))))

;; A span that stops short of the end carries the newline that ends its last
;; line; a span that runs to the end does not.
(define (auto-revert-hunk-text lines end n)
  (cond ((null? lines) "")
        ((>= end n) (string-join lines "\n"))
        (else (string-append (string-join lines "\n") "\n"))))

;; Last hunk first, so the line numbers of the earlier ones still hold.
(define (auto-revert-apply-hunks! buf hunks n)
  (for-each
    (lambda (h)
      (let* ((first (car h))
             (end (+ first (cadr h)))
             (start (auto-revert-line-byte buf first n))
             (stop (auto-revert-line-byte buf end n)))
        (buffer-replace-range! buf start (- stop start)
                               (auto-revert-hunk-text (caddr h) end n))))
    (reverse hunks)))

;; The text is replaced in place rather than by killing the buffer and
;; visiting it again: the buffer process, its locals, its group, its windows
;; and its provenance all survive. Point keeps its offset, clamped.
(define (auto-revert-take-file! buf disk)
  (let* ((p (buffer-point buf))
         (old (string-split (buffer-text buf) "\n"))
         (hunks (auto-revert-hunks old (string-split disk "\n"))))
    (with-edit-author "disk"
      (lambda ()
        (auto-revert-apply-hunks! buf hunks (length old))
        ;; An edit script that does not reproduce the file is a bug, and it
        ;; must not cost the user the file. The whole text is the fallback,
        ;; and it costs only the attribution the hunks were there to keep.
        (unless (equal? (buffer-text buf) disk)
          (buffer-delete-range! buf 0 (buffer-size buf))
          (buffer-append! buf disk))))
    ;; The buffer now holds exactly what the file holds. Saying so is the
    ;; point of the whole package: a reverted buffer that still read
    ;; modified would carry the very flag auto-revert exists to keep true.
    (buffer-mark-saved! buf)
    (with-current-buffer buf
      (lambda () (goto-char! (min p (buffer-size buf)))))
    (length hunks)))

(define (auto-revert-follow! buf)
  (let* ((path (buffer-path buf))
         (disk (and path (read-file path)))
         (text (buffer-text buf)))
    (cond
      ((not (string? disk)) #f)
      ;; Buffer and file agree, so the mark moves forward. This is also
      ;; how a save is noticed: the save's own file event lands here.
      ((equal? disk text)
       (auto-revert-base! buf text)
       (buffer-set-local! buf 'auto-revert-conflict #f)
       #f)
      ;; The buffer holds something the file never had. Whether it reads
      ;; modified decides nothing: work is work. Say it once, not on
      ;; every write the tree sees while the two stay apart.
      ((not (auto-revert-may-take? buf text))
       (unless (buffer-local buf 'auto-revert-conflict)
         (buffer-set-local! buf 'auto-revert-conflict #t)
         (message (string-append (abbreviate-file-name path)
                                 " changed on disk, and this buffer has edits of its own")))
       #f)
      (else
        ;; Every revert is said out loud. A buffer's text changing under the
        ;; user is not a quiet event, and the log is where they find out
        ;; which file moved and how much of it.
        (let ((n (auto-revert-take-file! buf disk)))
          (auto-revert-base! buf disk)
          (buffer-set-local! buf 'auto-revert-conflict #f)
          (message (string-append (abbreviate-file-name path)
                                  " followed its file, "
                                  (number->string n)
                                  (if (= n 1) " change" " changes")))
          #t)))))

;; One pass over every file buffer under the root that changed.
(define (auto-revert-fs-change root)
  (let loop ((bs (buffer-list)) (n 0))
    (if (null? bs)
        ;; Each buffer logged itself on the way past. One checkout can move
        ;; several at once, and only the last of those lines stays in the
        ;; echo area, so the count goes last and the detail stays above it.
        (when (> n 1)
          (message (string-append (number->string n)
                                  " buffers followed their files")))
        (let ((path (buffer-path (car bs))))
          (loop (cdr bs)
                (if (and path
                         ;; the root it was watched under, or failing that
                         ;; its own path, for a buffer watched before this
                         (or (equal? (buffer-local (car bs) 'auto-revert-root) root)
                             (string-prefix? root path))
                         (auto-revert-follows? (car bs))
                         (auto-revert-follow! (car bs)))
                    (+ n 1)
                    n))))))

;;; --- installed once -----------------------------------------------------------

;; Loading this file again must not add a second handler. The reverts are
;; idempotent, but the message is not, and hot reload is how the package
;; gets updated. The hooks call named functions, so a reload still
;; replaces the behaviour without replacing the registration.
(define *auto-revert-installed*
  (if (and (boundp '*auto-revert-installed*)
           (or (null? *auto-revert-installed*) (pair? *auto-revert-installed*)))
      *auto-revert-installed*
      '()))

(define (auto-revert-install! name thunk)
  (unless (member name *auto-revert-installed*)
    (set! *auto-revert-installed* (cons name *auto-revert-installed*))
    (thunk)))

;; find-file-hook is run by the visit command, not by the visit
;; function, so an agent or a script opening a file never reaches it.
;; buffer-created! is the seam every new buffer passes through, and it
;; runs after the text is loaded, which is exactly when buffer and file
;; agree.
(auto-revert-install! 'created
  (lambda ()
    (set! *buffer-created-hooks*
      (cons (lambda (name) (auto-revert-created! name)) *buffer-created-hooks*))))
(auto-revert-install! 'after-save
  (lambda () (add-hook! 'after-save-hook (lambda () (auto-revert-saved!)))))
(auto-revert-install! 'fs-change
  (lambda () (on-fs-change! (lambda (root) (auto-revert-fs-change root)))))

(auto-revert-watch-open-buffers!)

(public! 'auto-revert-on?
  "(auto-revert-on? FRAME) — #t when FRAME follows file changes on disk")
(public! 'auto-revert-set!
  "(auto-revert-set! FRAME ON?) — turn following on or off for one frame")
(public! 'auto-revert-follows?
  "(auto-revert-follows? BUF) — #t when BUF may take its file's text")
(public! 'auto-revert-follow!
  "(auto-revert-follow! BUF) — take the file's text when it differs and BUF still holds the text it last agreed with the file on")
(public! 'auto-revert-base
  "(auto-revert-base BUF) — the text BUF last agreed with its file on, or #f")

;; public! alone leaves a function in the fallback domain; the catalog
;; entry is what files it with the rest of the buffer verbs.
(for-each
  (lambda (name)
    (catalog-meta! 'function name 'domain 'buffers 'effects '(write)))
  '("auto-revert-on?" "auto-revert-set!"
    "auto-revert-follows?" "auto-revert-follow!" "auto-revert-base"))
