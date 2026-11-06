;;; tutorial.scm --- the learn-by-doing tutorial: C-h t.
;;;
;;; The master is bundled (priv/tutorials/COMPOS) and never changes. C-h t
;;; opens it as an app: one row per lesson, each lesson a page the reader
;;; edits while reading it, and its Try it boxes the steps of a wizard.
;;; The single TUTORIAL buffer below stays for onboarding.scm and
;;; training.scm, which stage it beside a guide chat.

(domain! 'learning)
(effects! '(read write))

(define *training-tutorial-buffer* "TUTORIAL")

(define (training-document-path)
  "Return the bundled, immutable tutorial master."
  (string-append (compos-priv-dir) "/tutorials/COMPOS"))

(define (training-state-dir)
  (string-append (compos-home) "/tutorial"))

(define (training-state-path)
  (string-append (training-state-dir) "/COMPOS.tut"))

(define (training-encode-state point text)
  (string-append (number->string point) "\n" text))

(define (training-decode-state raw)
  (and (string? raw)
       (let ((nl (string-index raw "\n")))
         (and nl
              (let* ((head (substring-bytes raw 0 nl))
                     (point (string->number head)))
                (and (re-match "^[0-9]+$" head)
                     (number? point)
                     (>= point 0)
                     (list point
                           (substring-bytes raw (+ nl 1) (string-byte-length raw)))))))))

(define (training-read-state)
  (let ((raw (read-file (training-state-path))))
    (and raw (training-decode-state raw))))

(define (training-save-state! buf)
  (make-directory! (training-state-dir))
  (write-file! (training-state-path)
               (training-encode-state (buffer-point buf) (buffer-text buf)))
  #t)

(define (training--format! buf)
  ;; Rendered, and still editable: morg draws it in place. A live copy that
  ;; lost its mode gets it back, so C-h t always shows the tutorial as made.
  (unless (equal? (buffer-local buf 'mode-name) "morg-mode")
    (with-current-buffer buf (lambda () (set-mode! "morg-mode"))))
  (unless (minor-mode-on? buf "preview-mode")
    (enable-minor-mode! buf "preview-mode"))
  (preview-heal! buf)
  buf)

(define (training--load-tutorial! text point)
  (let ((buf *training-tutorial-buffer*))
    (buffer-create buf)
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-insert! buf 0 text)
    (training--format! buf)
    (let ((point (max 0 (min point (buffer-size buf)))))
      (buffer-goto! buf point)
      (buffer-set-local! buf 'training-starting-point point))
    (buffer-set-local! buf 'training-tutorial #t)
    (buffer-mark-saved! buf)
    buf))

(define (training-fresh-tutorial!)
  (let ((text (read-file (training-document-path))))
    (if text
        (training--load-tutorial! text 0)
        (error "The bundled Compos tutorial is missing"))))

(define (training-resume-tutorial! state)
  (training--load-tutorial! (cadr state) (car state)))

(define (training--show! buf)
  (switch-to-buffer! buf)
  buf)

(define (training--prepare-document!)
  (if (buffer-known? *training-tutorial-buffer*)
      (training--format! (buffer-create *training-tutorial-buffer*))
      (let ((state (training-read-state)))
        (if state
            (training-resume-tutorial! state)
            (training-fresh-tutorial!)))))

(define (training--open-tutorial!)
  (training--show! (training--prepare-document!)))

;;; --- the tutorial app -------------------------------------------------------
;;; C-h t opens the tutorial as an app, a wizard: the listing has one row per
;;; lesson, and each lesson is its own page beside it, the reader's copy to
;;; practise in. A lesson's Try it boxes are its steps. Each step watches for
;;; the commands its keys name; when the reader runs them, the box fills and
;;; the next step is up. Progress lives in the content cache.

(effects! '(write display))

(define *tutorial-buffer* "*tutorial*")
(define *tutorial-app-id* "tutorial")
(define *tutorial-lessons* #f)
(define *tutorial-done* '())       ;; ((SLUG (N ...)) ...): the steps the reader finished
(define *tutorial-current* #f)     ;; the lesson whose steps are watched
(define *tutorial-watches* '())    ;; ((SLUG ((COMMAND ...) ...)) ...): what each step runs
(define *tutorial-watch* #f)       ;; (SLUG STEP (COMMAND ...)): the commands still to run
(define *tutorial-loaded* #f)

(define *tutorial-try* "> **Try it.**")

(define (tutorial--lesson title lines n)
  (let ((lines (filter (lambda (l) (not (equal? l "---"))) (reverse lines))))
    (list 'slug (string-downcase (re-replace-all "[^A-Za-z0-9]+" title "-"))
          'n n 'title title
          'body (string-trim (string-join lines "\n"))
          'steps (map (lambda (l)
                        (string-trim (substring-bytes l (string-byte-length *tutorial-try*)
                                                      (string-byte-length l))))
                      (filter (lambda (l) (string-prefix? *tutorial-try* l)) lines)))))

(define (tutorial--parse text)
  ;; one lesson per ## section of the master; Contents is the master's own
  ;; map, and the welcome above it opens the first lesson
  (let loop ((lines (string-split text "\n")) (title #f) (acc '()) (pre '()) (out '()))
    (let ((flush (lambda ()
                   (if (and title (not (equal? title "Contents")))
                       (cons (tutorial--lesson title (if (null? out) (append acc (list "") pre) acc)
                                               (+ 1 (length out)))
                             out)
                       out))))
      (cond ((null? lines) (reverse (flush)))
            ((string-prefix? "## " (car lines))
             (loop (cdr lines)
                   (string-trim (substring-bytes (car lines) 3 (string-byte-length (car lines))))
                   '() (if title pre acc) (flush)))
            ((and (not title) (string-prefix? "# " (car lines)))
             (loop (cdr lines) title acc pre out))
            (else (loop (cdr lines) title (cons (car lines) acc) pre out))))))

(define (tutorial-lessons)
  "The lessons of the bundled master, in order: plists of slug, n, title, body and steps."
  (or *tutorial-lessons*
      (let ((text (read-file (training-document-path))))
        (unless text (error "The bundled Compos tutorial is missing"))
        (set! *tutorial-lessons* (tutorial--parse text))
        *tutorial-lessons*)))

(define (tutorial-lesson slug)
  (find (lambda (l) (equal? (plist-get l 'slug) slug)) (tutorial-lessons)))

(define (tutorial--nth n)
  (find (lambda (l) (= (plist-get l 'n) n)) (tutorial-lessons)))

;;; progress

(define (tutorial--done-steps slug)
  (let ((hit (assoc slug *tutorial-done*))) (if hit (cadr hit) '())))

(define (tutorial-step-done? slug i) (and (member i (tutorial--done-steps slug)) #t))

(define (tutorial-lesson-done? l)
  ;; a lesson with no steps is done once it was read
  (let ((n (length (plist-get l 'steps)))
        (done (tutorial--done-steps (plist-get l 'slug))))
    (if (= n 0) (and (member 0 done) #t) (>= (length done) n))))

(define (tutorial--next-step l)
  (let loop ((i 0))
    (cond ((>= i (length (plist-get l 'steps))) #f)
          ((tutorial-step-done? (plist-get l 'slug) i) (loop (+ i 1)))
          (else i))))

(define (tutorial--save!)
  (cache-put! 'tutorial "progress"
    (string-join
      (cons (string-append "current " (or *tutorial-current* ""))
            (map (lambda (e) (string-join (cons (car e) (map number->string (cadr e))) " "))
                 *tutorial-done*))
      "\n")))

(define (tutorial--load!)
  (unless *tutorial-loaded*
    (set! *tutorial-loaded* #t)
    (let ((raw (cache-get 'tutorial "progress")))
      (when (string? raw)
        (for-each
          (lambda (line)
            (let ((ws (filter (lambda (w) (not (equal? w ""))) (string-split line " "))))
              (cond ((null? ws) #f)
                    ((equal? (car ws) "current")
                     (when (pair? (cdr ws)) (set! *tutorial-current* (cadr ws))))
                    (else (set! *tutorial-done*
                                (alist-put *tutorial-done* (car ws)
                                           (map string->number (cdr ws))))))))
          (string-split raw "\n"))))))

;;; what a step watches for

(define *tutorial-skip*
  '("keyboard-quit" "execute-extended-command" "universal-argument"
    "digit-argument" "negative-argument" "tutorial" "help-with-tutorial" "self-insert-command"))

(define (tutorial--spans text)
  (map (lambda (r) (substring-bytes text (+ (car r) 1) (- (cadr r) 1)))
       (or (re-find* "`[^`]+`" text) '())))

(define (tutorial--command name)
  (and (string? name) (member name (command-names)) name))

(define (tutorial--key-binding maps seq)
  ;; SEQ as the nearest of MAPS answers it
  (let loop ((maps maps))
    (and (pair? maps)
         (let ((r (ignore-errors (lambda () (keymap-lookup (car maps) seq)))))
           (if (string? r) r (loop (cdr maps)))))))

(define (tutorial--key-command span maps)
  ;; the fewest leading keys that name a command: C-h k C-M-v is describe-key.
  ;; A count in front (C-u 5 C-n, M-3 C-p) gives way to the key it counts.
  (let* ((keys (string-split span " "))
         (at (lambda (ks)
               (tutorial--command (tutorial--key-binding maps (string-join ks " "))))))
    (let loop ((n 1))
      (if (> n (length keys))
          #f
          (let ((cmd (at (list-head keys n))))
            (cond ((not cmd) (loop (+ n 1)))
                  ((member cmd *tutorial-skip*) (at (list (last keys))))
                  (else cmd)))))))

(define (tutorial--span-command span maps)
  (cond ((string-prefix? "M-x " span)
         (tutorial--command
           (car (string-split (substring-bytes span 4 (string-byte-length span)) " "))))
        ((re-match "^(C-|M-|s-)" span) (tutorial--key-command span maps))
        (else (tutorial--command span))))

(define (tutorial--step-watch text maps)
  (let loop ((spans (tutorial--spans text)) (out '()))
    (if (null? spans)
        (reverse out)
        (let ((c (tutorial--span-command (car spans) maps)))
          (loop (cdr spans)
                (if (and c (not (member c *tutorial-skip*)) (not (member c out)))
                    (cons c out)
                    out))))))

(define (tutorial--watches l)
  ;; keys resolve as they do on the lesson page, where the reader types them
  (let* ((slug (plist-get l 'slug))
         (hit (assoc slug *tutorial-watches*)))
    (if hit
        (cadr hit)
        (let* ((buf (tutorial-lesson-buffer l))
               (maps (if (buffer-known? buf) (buffer-keymaps buf) (list "global")))
               (ws (map (lambda (s) (tutorial--step-watch s maps)) (plist-get l 'steps))))
          (set! *tutorial-watches* (alist-put *tutorial-watches* slug ws))
          ws))))

(define (tutorial--arm!)
  (let* ((l (and *tutorial-current* (tutorial-lesson *tutorial-current*)))
         (i (and l (tutorial--next-step l))))
    (set! *tutorial-watch*
          (and i (list (plist-get l 'slug) i (list-ref (tutorial--watches l) i))))))

(define *tutorial-mx* #f)

(define (tutorial--ran)
  ;; the command that just ran. M-x runs its command from minibuffer-confirm,
  ;; so a confirmed M-x answers the name it ran, from its history.
  (let ((cmd (this-command)))
    (cond ((equal? cmd "execute-extended-command") (set! *tutorial-mx* #t) cmd)
          ((and *tutorial-mx* (equal? cmd "minibuffer-confirm"))
           (set! *tutorial-mx* #f)
           (let ((h (history-items 'M-x))) (if (pair? h) (car h) cmd)))
          ((and (string? cmd) (string-contains? cmd "quit")) (set! *tutorial-mx* #f) cmd)
          (else cmd))))

(define (tutorial--after-command)
  (let ((w *tutorial-watch*))
    (when w
      (let ((cmd (tutorial--ran)))
        (when (and (string? cmd) (member cmd (caddr w)))
          (let ((left (filter (lambda (c) (not (equal? c cmd))) (caddr w))))
            (set! *tutorial-watch* (list (car w) (cadr w) left))
            (if (null? left)
                (tutorial--prove! (car w) (cadr w))
                (message (string-append "Good. Still to do in this step: "
                                        (string-join left ", "))))))))))

;; A command that only starts the work (a key check, a daemon start) proves
;; the step when the work answers: PROOF takes PASS and FAIL, and calls one.
(define *tutorial-proofs* '())   ;; ((COMMAND PROOF) ...)

(define (tutorial-proof! command proof)
  (set! *tutorial-proofs* (alist-put *tutorial-proofs* command proof))
  command)

(define (tutorial--prove! slug i)
  (let* ((l (tutorial-lesson slug))
         (ran (if l (list-ref (tutorial--watches l) i) '()))
         (hit (find (lambda (c) (assoc c *tutorial-proofs*)) ran)))
    (if (not hit)
        (tutorial-step-done! slug i)
        (begin
          (message "Checking that it works...")
          ((cadr (assoc hit *tutorial-proofs*))
           (lambda () (tutorial-step-done! slug i))
           (lambda (why) (tutorial--arm!) (message why)))))))

(add-hook! 'post-command-hook 'tutorial--after-command)

;;; the lesson page

(define (tutorial-lesson-buffer l)
  (string-append "*tutorial:" (plist-get l 'slug) "*"))

(define (tutorial--progress-line l)
  (let ((n (length (plist-get l 'steps)))
        (done (length (tutorial--done-steps (plist-get l 'slug))))
        (of (string-append "Lesson " (number->string (plist-get l 'n)) " of "
                           (number->string (length (tutorial-lessons))))))
    (string-append "*" of " - "
                   (cond ((= n 0) "read it, then go on with C-c C-n")
                         ((>= done n) "every step is done. C-c C-n goes on")
                         (else (string-append (number->string done) " of " (number->string n)
                                              " steps done. A box fills when you do its step;"
                                              " C-c C-c ticks it by hand")))
                   "*")))

(define (tutorial--step-line l i)
  (string-append (if (tutorial-step-done? (plist-get l 'slug) i) "- [x] " "- [ ] ")
                 "**Try it.** " (list-ref (plist-get l 'steps) i)))

(define *tutorial-nav*
  "[<- Previous](compos:tutorial/previous) | [All lessons](compos:tutorial/lessons) | [Next ->](compos:tutorial/next)")

(define (tutorial--page-text l)
  (let loop ((lines (string-split (plist-get l 'body) "\n")) (i 0) (out '()))
    (cond ((null? lines)
           (string-append "# " (number->string (plist-get l 'n)) ". " (plist-get l 'title) "\n\n"
                          (tutorial--progress-line l) "\n\n" *tutorial-nav* "\n\n"
                          (string-join (reverse out) "\n")
                          "\n\n---\n\n" *tutorial-nav* "\n"))
          ((string-prefix? *tutorial-try* (car lines))
           (loop (cdr lines) (+ i 1) (cons (tutorial--step-line l i) out)))
          (else (loop (cdr lines) i (cons (car lines) out))))))

(define (tutorial--render! buf l)
  (buffer-set-read-only! buf #f)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-insert! buf 0 (tutorial--page-text l))
  (buffer-set-local! buf 'tutorial-lesson (plist-get l 'slug))
  (buffer-set-local! buf 'tutorial-progress (tutorial--progress-line l))
  (unless (buffer-derived-mode? buf "tutorial-lesson-mode")
    (with-current-buffer buf (lambda () (set-mode! "tutorial-lesson-mode"))))
  (unless (minor-mode-on? buf "preview-mode") (enable-minor-mode! buf "preview-mode"))
  (preview-heal! buf)
  (buffer-goto! buf 0)
  (buffer-mark-saved! buf)
  buf)

(define (tutorial--sync-page! l)
  ;; the boxes and the progress line change in place: the rest of the page
  ;; is the reader's practice, and stays as they left it
  (let ((buf (tutorial-lesson-buffer l)))
    (when (buffer-known? buf)
      (let loop ((i 0) (steps (plist-get l 'steps)))
        (unless (null? steps)
          (let ((want (tutorial--step-line l i)))
            (for-each (lambda (box)
                        (let ((have (string-append box "**Try it.** " (car steps))))
                          (when (and (not (equal? have want))
                                     (string-contains? (buffer-text buf) have))
                            (buffer-replace! buf have want))))
                      '("- [ ] " "- [x] ")))
          (loop (+ i 1) (cdr steps))))
      (let ((old (buffer-local buf 'tutorial-progress))
            (new (tutorial--progress-line l)))
        (when (and old (not (equal? old new)))
          (buffer-replace! buf old new)
          (buffer-set-local! buf 'tutorial-progress new)))
      (preview-heal! buf))))

(define (tutorial--join! buf role)
  (when (buffer-exists? buf)
    (app-claim! buf *tutorial-app-id* role)
    (buffer-join-here! buf))
  buf)

(define (tutorial--page! l)
  ;; the lesson's page is made once: later visits find the reader's own copy
  (let ((buf (tutorial-lesson-buffer l)))
    (unless (buffer-known? buf)
      (buffer-create buf)
      (tutorial--render! buf l))
    (tutorial--join! buf 'detail)))

(define (tutorial--changed! l)
  (tutorial--save!)
  (tutorial--arm!)
  (when l (tutorial--sync-page! l))
  (when (buffer-known? *tutorial-buffer*) (list-refresh! *tutorial-buffer*)))

(define (tutorial--enter! l)
  (set! *tutorial-current* (plist-get l 'slug))
  (when (and (null? (plist-get l 'steps)) (not (tutorial-lesson-done? l)))
    (set! *tutorial-done* (alist-put *tutorial-done* (plist-get l 'slug) (list 0))))
  (tutorial--changed! l)
  l)

(define (tutorial-step-done! slug i)
  "Mark step I of lesson SLUG done: its box fills, and the next step is watched."
  (let ((l (tutorial-lesson slug)))
    (when (and l (not (tutorial-step-done? slug i)))
      (set! *tutorial-done*
            (alist-put *tutorial-done* slug (append (tutorial--done-steps slug) (list i))))
      (tutorial--changed! l)
      (if (tutorial-lesson-done? l)
          (tutorial--advance! l)
          (tutorial--show-step! l)))))

(define (tutorial--show-step! l)
  ;; the page beside you turns to the next step; a page you type in keeps
  ;; your point, and the echo area names the step instead
  (let* ((i (tutorial--next-step l))
         (buf (tutorial-lesson-buffer l))
         (w (and (buffer-known? buf) (window-showing buf))))
    (when i
      (when (and w (not (equal? w (active-window))))
        (let ((pos (string-index (buffer-text buf) "- [ ] **Try it.**")))
          (when pos (window-set-point! w pos))))
      (message (string-append "Done. Next: " (list-ref (plist-get l 'steps) i))))))

(define (tutorial--advance! l)
  ;; a finished lesson gives its window to the next one
  (let ((to (tutorial--nth (+ (plist-get l 'n) 1))))
    (if (not to)
        (message "You finished the last lesson of the tutorial")
        (let* ((buf (tutorial--page! to))
               (from (tutorial-lesson-buffer l))
               (w (and (buffer-known? from) (window-showing from))))
          (tutorial--enter! to)
          (when (buffer-known? *tutorial-buffer*)
            (list-goto-index! *tutorial-buffer* (- (plist-get to 'n) 1)))
          (when w
            (window-set-buffer! w buf)
            (display-buffer-detail! buf *tutorial-buffer*))
          (message (string-append "Lesson done: " (plist-get l 'title) ". Next: "
                                  (number->string (plist-get to 'n)) ". " (plist-get to 'title)))))))

;;; the listing

(define (tutorial--cells buf l)
  (let ((n (length (plist-get l 'steps)))
        (done (length (tutorial--done-steps (plist-get l 'slug)))))
    (list (list (cond ((tutorial-lesson-done? l) "x")
                      ((equal? (plist-get l 'slug) *tutorial-current*) ">")
                      (else ""))
                "default")
          (list (number->string (plist-get l 'n)) "dim")
          (list (if (= n 0) "read" (string-append (number->string (min done n)) "/" (number->string n)))
                "dim")
          (list (plist-get l 'title) "default"))))

(define (tutorial--title buf)
  (let ((ls (tutorial-lessons)))
    (string-append "Compos tutorial - " (number->string (length (filter tutorial-lesson-done? ls)))
                   " of " (number->string (length ls)) " lessons done")))

(define-list-mode! "tutorial-mode"
  (list
    'doc (string-append
           "The Compos tutorial, one row per lesson. Moving the point shows the lesson beside "
           "the list; RET also moves you into it to practise. A lesson's Try it boxes are its "
           "steps: do a step and its box fills by itself. In a lesson, C-c C-n and C-c C-p go "
           "to the next and previous lesson, C-c C-c ticks the next step by hand, C-c C-r starts "
           "the lesson again from the master, and C-c C-l comes back here. On this list, d marks "
           "a lesson done or not done, R resets all progress, g redraws, / narrows, and q quits.")
    'buffer *tutorial-buffer*
    'transient #f
    'rows (lambda (buf) (tutorial-lessons))
    'key (lambda (buf l) (plist-get l 'slug))
    'preview (lambda (buf l) (tutorial-show-lesson! l))
    'columns (lambda (buf) (list (list "" 2) (list "#" 3) (list "steps" 6) (list "lesson" #f)))
    'cells tutorial--cells
    'title tutorial--title
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "start") ("d" "done") ("R" "reset") ("/" "filter") ("q" "quit")))
    'keys '(("RET" "tutorial-start-lesson") ("d" "tutorial-toggle-done")
            ("R" "tutorial-reset") ("g" "tutorial-refresh") ("q" "quit-window"))))

(define-derived-mode "tutorial-lesson-mode" "morg-mode" (lambda () #t))

(mode-keys! "tutorial-lesson-mode"
  '(("C-c C-n" "tutorial-next-lesson") ("C-c C-p" "tutorial-previous-lesson")
    ("C-c C-c" "tutorial-tick-step") ("C-c C-r" "tutorial-restart-lesson")
    ("C-c C-l" "tutorial-lessons")))

;;; moving through it

(define (tutorial-listing!)
  "The listing buffer, made and joined to this group."
  (unless (buffer-exists? *tutorial-buffer*) (buffer-create *tutorial-buffer*))
  (tutorial--join! *tutorial-buffer* 'home)
  (unless (buffer-derived-mode? *tutorial-buffer* "tutorial-mode")
    (with-current-buffer *tutorial-buffer* (lambda () (set-mode! "tutorial-mode"))))
  *tutorial-buffer*)

(define (tutorial-show-lesson! l)
  "Show lesson L beside the listing; the focus stays where it is."
  (when l
    (let ((buf (tutorial--page! l)))
      (tutorial--enter! l)
      (display-buffer-detail! buf *tutorial-buffer*)
      buf)))

(define (tutorial--first-open)
  (or (find (lambda (l) (not (tutorial-lesson-done? l))) (tutorial-lessons))
      (car (tutorial-lessons))))

(define (tutorial-open!)
  "Open the tutorial here: the lessons, and the lesson you are on beside them."
  (tutorial--load!)
  (let* ((buf (tutorial-listing!))
         (l (or (and *tutorial-current* (tutorial-lesson *tutorial-current*))
                (tutorial--first-open)))
         (page (tutorial--page! l)))
    (tutorial--enter! l)
    (list-goto-index! buf (- (plist-get l 'n) 1))
    (app-open! buf page)
    buf))

(define (tutorial--current-lesson)
  (or (let ((s (buffer-local (current-buffer) 'tutorial-lesson))) (and s (tutorial-lesson s)))
      (and *tutorial-current* (tutorial-lesson *tutorial-current*))))

(define (tutorial--go! l)
  ;; from a lesson page the next lesson takes the same window; from
  ;; anywhere else it opens beside the listing
  (let ((buf (tutorial--page! l)))
    (tutorial--enter! l)
    (when (buffer-known? *tutorial-buffer*)
      (list-goto-index! *tutorial-buffer* (- (plist-get l 'n) 1)))
    (when (buffer-local (current-buffer) 'tutorial-lesson)
      (switch-to-buffer-here! buf))
    (display-buffer-detail! buf *tutorial-buffer*)
    (message (string-append "Lesson " (number->string (plist-get l 'n)) ": " (plist-get l 'title)))
    buf))

(define (tutorial--move! dir)
  (tutorial--load!)
  (let ((l (tutorial--current-lesson)))
    (if (not l)
        (tutorial-open!)
        (let ((to (tutorial--nth (+ (plist-get l 'n) dir))))
          (if to
              (tutorial--go! to)
              (message (if (> dir 0) "This is the last lesson" "This is the first lesson")))))))

(define (tutorial-tick-step!)
  "Mark the next step of the lesson you are on done, by hand."
  (let* ((l (tutorial--current-lesson))
         (i (and l (tutorial--next-step l))))
    (cond ((not l) (message "No lesson is open"))
          ((not i) (message "Every step of this lesson is done. C-c C-n goes on"))
          (else (tutorial-step-done! (plist-get l 'slug) i)))))

(define (tutorial-restart-lesson!)
  "Start the lesson you are on again: a fresh page from the master, no steps done."
  (let ((l (tutorial--current-lesson)))
    (when l
      (set! *tutorial-done* (alist-put *tutorial-done* (plist-get l 'slug) '()))
      (let ((buf (tutorial-lesson-buffer l)))
        (when (buffer-known? buf) (tutorial--render! buf l)))
      (tutorial--enter! l)
      (message (string-append "Started again: " (plist-get l 'title))))))

(define (tutorial-toggle-done!)
  "Mark the lesson on this row done, or not done."
  (let ((l (list-current *tutorial-buffer*)))
    (when l
      (let ((n (length (plist-get l 'steps))))
        (set! *tutorial-done*
              (alist-put *tutorial-done* (plist-get l 'slug)
                         (cond ((tutorial-lesson-done? l) '())
                               ((= n 0) (list 0))
                               (else (iota n)))))
        (tutorial--changed! l)))))

(define (tutorial-reset!)
  "Forget all tutorial progress, after asking."
  (y-or-n "Forget all tutorial progress and start every lesson again?"
    (lambda ()
      (set! *tutorial-done* '())
      (set! *tutorial-current* #f)
      (for-each (lambda (l)
                  (let ((b (tutorial-lesson-buffer l)))
                    (when (buffer-known? b) (tutorial--render! b l))))
                (tutorial-lessons))
      (tutorial--changed! #f)
      (message "Tutorial progress reset"))
    (lambda () (message "Kept your progress"))))

(define (tutorial-show-lessons!)
  (let ((w (window-showing *tutorial-buffer*)))
    (if w (select-window! w) (tutorial-open!))))

;;;###autoload
(define-command "tutorial"
  "Open the Compos tutorial: lessons you practise one step at a time"
  (lambda () (tutorial-open!)))

(define-command "help-with-tutorial"
  "Open the Compos tutorial at the lesson you are on"
  (lambda () (tutorial-open!)))

(define-command "tutorial-start-lesson" "Show the lesson on this row and move into it"
  (lambda ()
    (let* ((buf (tutorial-show-lesson! (list-current *tutorial-buffer*)))
           (w (and buf (window-showing buf))))
      (when w (select-window! w)))))

(define-command "tutorial-next-lesson" "Go to the next lesson"
  (lambda () (tutorial--move! 1)))

(define-command "tutorial-previous-lesson" "Go to the previous lesson"
  (lambda () (tutorial--move! -1)))

(define-command "tutorial-tick-step" "Mark the next step of this lesson done"
  (lambda () (tutorial-tick-step!)))

(define-command "tutorial-restart-lesson" "Start this lesson again from the master"
  (lambda () (tutorial-restart-lesson!)))

(define-command "tutorial-lessons" "Go to the list of lessons"
  (lambda () (tutorial-show-lessons!)))

(define-command "tutorial-toggle-done" "Mark the lesson on this row done, or not done"
  (lambda () (tutorial-toggle-done!)))

(define-command "tutorial-reset" "Forget all tutorial progress"
  (lambda () (tutorial-reset!)))

(define-command "tutorial-refresh" "Redraw the list of lessons"
  (lambda () (list-refresh! *tutorial-buffer*)))

(define (tutorial--link arg)
  (cond ((equal? arg "next") (tutorial--move! 1) #t)
        ((equal? arg "previous") (tutorial--move! -1) #t)
        ((equal? arg "lessons") (tutorial-show-lessons!) #t)
        (else #f)))

(add-hook! (list 'preview-link "tutorial") tutorial--link)

;; JEV and laya steps are done when they answer, not when they are asked
(tutorial-proof! "jev"
  (lambda (pass fail)
    (task-run! (lambda () (and (boundp 'jev-api-key) (jev-api-key)))
      (lambda (ok? key)
        (if (and ok? key)
            (pass)
            (fail "JEV has no API key. Set TYPESAFE_API_KEY, then type M-x jev again."))))))

(tutorial-proof! "laya-server"
  (lambda (pass fail)
    (if (not (boundp 'laya-ask))
        (fail "laya is not loaded in this editor")
        (laya-ask '(op "models")
          (lambda (reply)
            (if (plist-get reply 'ok)
                (pass)
                (fail (string-append "laya does not answer: " (or (plist-get reply 'error) "no answer")
                                     ". Read ~/.compos/laya-daemon.log, then type M-x laya-server again."))))))))

;; the extension step is done when an extension is attached, whatever the
;; tab list says
(tutorial-proof! "list-tabs"
  (lambda (pass fail)
    (if (browser-connected?)
        (pass)
        (fail "No browser extension is connected. Load the extension folder at chrome://extensions, then type M-x list-tabs again."))))

;; the steps are watched from the start, not only once C-h t is open
(ignore-errors (lambda () (tutorial--load!) (tutorial--arm!)))

;; A new reader often keeps Control held for the second key.
(define-key "help-map" "t" "help-with-tutorial")
(define-key "help-map" "C-t" "help-with-tutorial")

;; The welcome page links compos:training/tutorial. The companion app
;; answers the other training links when the user init loads it.
(define (tutorial--follow-link arg)
  (and (equal? arg "tutorial")
       (begin (run-command "help-with-tutorial") #t)))

(add-hook! (list 'preview-link "training") tutorial--follow-link)

(category! 'learning)
(public! 'training-document-path
  "(training-document-path) — the bundled immutable tutorial master")
(public! 'training-state-path
  "(training-state-path) — the reader's saved tutorial content and point")
(public! 'tutorial-lessons
  "(tutorial-lessons) — the tutorial's lessons in order: plists of slug, n, title, body and steps")
(public! 'tutorial-open!
  "(tutorial-open!) — open the tutorial app here, at the lesson the reader is on")
(public! 'tutorial-step-done!
  "(tutorial-step-done! SLUG I) — mark step I of lesson SLUG done; its box fills")
