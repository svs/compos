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
;;; C-h t opens three panes: *tutorial*, the practice page you type in;
;;; *tutorial-detail*, the slide that teaches one small step at a time; and
;;; *tutorial-lesson*, the lesson to read. *tutorial-index*, the list of
;;; lessons, comes over the practice pane when asked and goes with q.
;;; Each step watches for the commands its keys name; when the reader runs
;;; them, the slide moves on by itself.

(effects! '(write display))

(define *tutorial-buffer* "*tutorial*")
(define *tutorial-detail-buffer* "*tutorial-detail*")
(define *tutorial-lesson-buffer* "*tutorial-lesson*")
(define *tutorial-index-buffer* "*tutorial-index*")
(define *tutorial-app-id* "tutorial")
(define *tutorial-lessons* #f)
(define *tutorial-done* '())       ;; ((SLUG (N ...)) ...): the steps the reader finished
(define *tutorial-current* #f)     ;; the lesson on the slide
(define *tutorial-shown* 0)        ;; the step on the slide
(define *tutorial-steps* '())      ;; ((SLUG ((TEXT (COMMAND ...)) ...)) ...)
(define *tutorial-watch* #f)       ;; (SLUG STEP (COMMAND ...)): the commands still to run
(define *tutorial-help* #f)        ;; what went wrong with the step on the slide, or #f
(define *tutorial-loaded* #f)

(define *tutorial-try* "> **Try it.**")

;;; the master

(define (tutorial--readings lines)
  ;; the lesson cut at its Try it boxes: reading K is what leads up to Try it
  ;; K, and the last one keeps the text after the last box. The boxes
  ;; themselves are the slide's.
  (let loop ((ls lines) (acc '()) (out '()))
    (cond ((null? ls)
           (let ((tail (string-trim (string-join (reverse acc) "\n"))))
             (reverse (cond ((null? out) (list tail))
                            ((equal? tail "") out)
                            (else (cons (string-append (car out) "\n\n" tail) (cdr out)))))))
          ((string-prefix? *tutorial-try* (car ls))
           ;; text above a ### heading follows the box before it, so it
           ;; stays with that box's reading
           (let* ((chunk (reverse acc))
                  (head (let find ((xs chunk) (i 0))
                          (cond ((null? xs) #f)
                                ((string-prefix? "### " (car xs)) i)
                                (else (find (cdr xs) (+ i 1))))))
                  (before (if (and head (pair? out)) (string-trim (string-join (list-head chunk head) "\n")) ""))
                  (rest (if (and head (pair? out)) (list-tail chunk head) chunk))
                  (out (if (equal? before "") out (cons (string-trim (string-append (car out) "\n\n" before)) (cdr out)))))
             (loop (cdr ls) '() (cons (string-trim (string-join rest "\n")) out))))
          (else (loop (cdr ls) (cons (car ls) acc) out)))))

(define (tutorial--lesson title lines n)
  (let ((lines (filter (lambda (l) (not (equal? l "---"))) (reverse lines))))
    (list 'slug (string-downcase (re-replace-all "[^A-Za-z0-9]+" title "-"))
          'n n 'title title
          'body (string-trim (string-join lines "\n"))
          'readings (tutorial--readings lines)
          'tries (map (lambda (l)
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
  "The lessons of the bundled master, in order: plists of slug, n, title, body and tries."
  (or *tutorial-lessons*
      (let ((text (read-file (training-document-path))))
        (unless text (error "The bundled Compos tutorial is missing"))
        (set! *tutorial-lessons* (tutorial--parse text))
        *tutorial-lessons*)))

(define (tutorial-lesson slug)
  (find (lambda (l) (equal? (plist-get l 'slug) slug)) (tutorial-lessons)))

(define (tutorial--nth n)
  (find (lambda (l) (= (plist-get l 'n) n)) (tutorial-lessons)))

(define (tutorial--lesson-now)
  (and *tutorial-current* (tutorial-lesson *tutorial-current*)))

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
        ;; a key: a chord, or a named key such as <home>; Shift and an arrow
        ;; selects text but is bound to pane moves, so it is not watched
        ((re-match "^(C-|M-|s-|<)" span) (tutorial--key-command span maps))
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

;;; the steps: a Try it cut into bites

(define (tutorial--sentences text)
  (let loop ((parts (string-split text ". ")) (out '()))
    (cond ((null? parts) (reverse out))
          ((null? (cdr parts)) (reverse (cons (car parts) out)))
          (else (loop (cdr parts) (cons (string-append (car parts) ".") out))))))

(define (tutorial--bites try maps)
  ;; one step per thing to do: a sentence that names a command starts a
  ;; step, and a sentence that names none explains the step it is in
  (let loop ((ss (tutorial--sentences try)) (cur #f) (out '()))
    (if (null? ss)
        (reverse (if cur (cons cur out) out))
        (let* ((s (car ss))
               (w (tutorial--step-watch s maps)))
          (cond ((not cur) (loop (cdr ss) (list s w) out))
                ((null? w) (loop (cdr ss) (list (string-append (car cur) " " s) (cadr cur)) out))
                ((null? (cadr cur)) (loop (cdr ss) (list (string-append (car cur) " " s) w) out))
                (else (loop (cdr ss) (list s w) (cons cur out))))))))

(define (tutorial--steps l)
  ;; keys resolve as they do in the practice pane, where the reader types them
  (let* ((slug (plist-get l 'slug))
         (hit (assoc slug *tutorial-steps*)))
    (if hit
        (cadr hit)
        (let* ((maps (if (buffer-known? *tutorial-buffer*)
                         (buffer-keymaps *tutorial-buffer*)
                         (list "global")))
               ;; a step is (TEXT COMMANDS READING): READING is the part of
               ;; the lesson its Try it belongs to
               (steps (let loop ((ts (plist-get l 'tries)) (k 0) (out '()))
                        (if (null? ts)
                            out
                            (loop (cdr ts) (+ k 1)
                                  (append out (map (lambda (b) (append b (list k)))
                                                   (tutorial--bites (car ts) maps))))))))
          (set! *tutorial-steps* (alist-put *tutorial-steps* slug steps))
          steps))))

(define (tutorial--step-count l) (length (tutorial--steps l)))

;;; progress

(define (tutorial--done-steps slug)
  (let ((hit (assoc slug *tutorial-done*))) (if hit (cadr hit) '())))

(define (tutorial-step-done? slug i) (and (member i (tutorial--done-steps slug)) #t))

(define (tutorial-lesson-done? l)
  ;; a lesson with no steps is done once it was read
  (let ((n (tutorial--step-count l))
        (done (tutorial--done-steps (plist-get l 'slug))))
    (if (= n 0) (and (member 0 done) #t) (>= (length done) n))))

(define (tutorial--next-step l)
  (let loop ((i 0))
    (cond ((>= i (tutorial--step-count l)) #f)
          ((tutorial-step-done? (plist-get l 'slug) i) (loop (+ i 1)))
          (else i))))

(define (tutorial--mark! slug i)
  (unless (tutorial-step-done? slug i)
    (set! *tutorial-done*
          (alist-put *tutorial-done* slug (append (tutorial--done-steps slug) (list i))))))

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
          (string-split raw "\n"))))
    (let ((l (tutorial--lesson-now)))
      (when l (set! *tutorial-shown* (or (tutorial--next-step l) 0))))))

;;; watching the reader

(define (tutorial--arm!)
  (let* ((l (tutorial--lesson-now))
         (steps (if l (tutorial--steps l) '()))
         (i *tutorial-shown*))
    (set! *tutorial-watch*
          (and l (< i (length steps))
               (not (tutorial-step-done? (plist-get l 'slug) i))
               (list (plist-get l 'slug) i (cadr (list-ref steps i)))))
    (tutorial-recheck!)
    (tutorial--probe!)))

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
                (message (string-append "Good. Still to do: " (string-join left ", "))))))))))

(add-hook! 'post-command-hook 'tutorial--after-command)

;; A command that only starts the work (a key check, a daemon start) proves
;; the step when the work answers: PROOF takes PASS and FAIL, and calls one.
(define *tutorial-proofs* '())   ;; ((COMMAND PROOF) ...)

(define (tutorial-proof! command proof)
  (set! *tutorial-proofs* (alist-put *tutorial-proofs* command proof))
  command)

(define (tutorial--trouble! why)
  "Show WHY on the slide, and tell tutorial-trouble-hook."
  (set! *tutorial-help* why)
  (tutorial--draw-detail!)
  (message why)
  (run-hook-with-args 'tutorial-trouble-hook *tutorial-current* why))

(define (tutorial--prove! slug i)
  (let* ((l (tutorial-lesson slug))
         (ran (if l (cadr (list-ref (tutorial--steps l) i)) '()))
         (hit (find (lambda (c) (assoc c *tutorial-proofs*)) ran)))
    (if (not hit)
        (tutorial-step-done! slug i)
        (begin
          (message "Checking that it works...")
          ((cadr (assoc hit *tutorial-proofs*))
           (lambda () (tutorial-step-done! slug i))
           (lambda (why) (tutorial--arm!) (tutorial--trouble! why)))))))

;; A step that waits for the world, not for a command: the step of lesson
;; SLUG whose text has TEXT is done when READY? answers true. It is asked
;; when the step comes up, and again when a hook calls tutorial-recheck!.
(define *tutorial-awaits* '())   ;; ((SLUG TEXT READY?) ...)

(define (tutorial-await! slug text ready?)
  (set! *tutorial-awaits*
        (cons (list slug text ready?)
              (filter (lambda (a) (not (and (equal? (car a) slug) (equal? (cadr a) text))))
                      *tutorial-awaits*)))
  slug)

(define (tutorial--await-of slug text)
  (find (lambda (a) (and (equal? (car a) slug) (string-contains? text (cadr a))))
        *tutorial-awaits*))

;; A step that starts its own work when it comes up: the step of lesson
;; SLUG whose text has TEXT runs PROBE, which calls PASS or FAIL.
(define *tutorial-probes* '())   ;; ((SLUG TEXT PROBE) ...)
(define *tutorial-probing* #f)   ;; (SLUG STEP) while a probe runs

(define (tutorial-probe! slug text probe)
  (set! *tutorial-probes*
        (cons (list slug text probe)
              (filter (lambda (p) (not (and (equal? (car p) slug) (equal? (cadr p) text))))
                      *tutorial-probes*)))
  slug)

(define (tutorial--probe!)
  (let* ((w *tutorial-watch*)
         (l (and w (tutorial-lesson (car w))))
         (text (and l (car (list-ref (tutorial--steps l) (cadr w)))))
         (p (and text (find (lambda (p) (and (equal? (car p) (car w)) (string-contains? text (cadr p))))
                            *tutorial-probes*))))
    (when (and p (not (equal? *tutorial-probing* (list (car w) (cadr w)))))
      (let ((slug (car w)) (i (cadr w)))
        (set! *tutorial-probing* (list slug i))
        ((caddr p)
         (lambda () (set! *tutorial-probing* #f) (tutorial-step-done! slug i))
         (lambda (why) (set! *tutorial-probing* #f) (tutorial--trouble! why)))))))

(define (tutorial-recheck!)
  "Finish the step on the slide when the thing it waits for is there."
  (let* ((w *tutorial-watch*)
         (l (and w (tutorial-lesson (car w)))))
    (when l
      (let ((a (tutorial--await-of (car w) (car (list-ref (tutorial--steps l) (cadr w))))))
        (when (and a (ignore-errors (caddr a)))
          (tutorial-step-done! (car w) (cadr w)))))))

(define (tutorial-step-done! slug i)
  "Mark step I of lesson SLUG done: the slide moves on, and so does a finished lesson."
  (let ((l (tutorial-lesson slug)))
    (when (and l (not (tutorial-step-done? slug i)))
      (tutorial--mark! slug i)
      (set! *tutorial-help* #f)
      (if (tutorial-lesson-done? l)
          (let ((to (tutorial--nth (+ (plist-get l 'n) 1))))
            (if to
                (begin (tutorial--go! to)
                       (message (string-append "Lesson done. Next: " (plist-get to 'title))))
                (begin (tutorial--changed!)
                       (message "You finished the tutorial"))))
          (begin
            (when (equal? slug *tutorial-current*)
              (set! *tutorial-shown* (or (tutorial--next-step l) i)))
            (tutorial--changed!)
            (message "Done. Next step."))))))

;;; keys as people know them

;; The master writes keys the Emacs way, and the watch reads them so. The
;; reader sees the keyboard's own symbols: C-x o is ⌃X O, s-<right> is ⌘→.
(define *tutorial-modifiers* '(("C-" "⌃") ("M-" "⌥") ("S-" "⇧") ("s-" "⌘")))

(define *tutorial-key-names*
  '(("RET" "⏎") ("<return>" "⏎") ("SPC" "Space") ("TAB" "⇥") ("<tab>" "⇥")
    ("DEL" "⌫") ("<backspace>" "⌫") ("<delete>" "⌦") ("ESC" "esc")
    ("<left>" "←") ("<right>" "→") ("<up>" "↑") ("<down>" "↓")
    ("<home>" "Home") ("<end>" "End") ("<prior>" "PageUp") ("<next>" "PageDown")))

(define (tutorial--key-label token)
  ;; one key as symbols, or #f when TOKEN is not a key
  (let loop ((t token) (mods '()))
    (let ((m (find (lambda (p) (and (string-prefix? (car p) t) (> (string-length t) 1))) *tutorial-modifiers*)))
      (if m
          (loop (substring t 2 (string-length t)) (cons (car m) mods))
          (let* ((sym (apply string-append
                             (map cadr (filter (lambda (p) (member (car p) mods)) *tutorial-modifiers*))))
                 (named (assoc t *tutorial-key-names*))
                 (base (cond ((equal? t "") (and (pair? mods) ""))
                             (named (cadr named))
                             ;; a chord names its letter as the keycap does; a
                             ;; lone letter stays as typed, since N is Shift-n
                             ((= (string-length t) 1) (if (pair? mods) (string-upcase t) t))
                             (else #f))))
            (and base (or (pair? mods) named (= (string-length t) 1))
                 (string-append sym base)))))))

(define (tutorial--keys-label span)
  ;; a span that starts with a key: each key as symbols, the rest as it is
  (let ((tokens (string-split span " ")))
    (if (tutorial--key-label (car tokens))
        (string-join (map (lambda (t) (or (tutorial--key-label t) t)) tokens) " ")
        span)))

(define (tutorial--symbolize text)
  "TEXT with every `key` in it written as the keyboard's symbols."
  (let loop ((parts (string-split text "`")) (code? #f) (out '()))
    (if (null? parts)
        (string-join (reverse out) "`")
        (loop (cdr parts) (not code?)
              (cons (if code? (tutorial--keys-label (car parts)) (car parts)) out)))))

;;; the slide

(define (tutorial--say text)
  ;; `keys` stand out on the slide; the rest is plain
  (let loop ((parts (string-split (tutorial--symbolize text) "`")) (code? #f) (out '()))
    (if (null? parts)
        (reverse out)
        (loop (cdr parts) (not code?)
              (if (equal? (car parts) "")
                  out
                  (cons (list (if code? "tutorial-key" "tutorial-text") (car parts)) out))))))

(define (tutorial--div class &rest more)
  (append (list 'tag "div" 'class class) more))

(define (tutorial--detail-blocks)
  (let ((l (tutorial--lesson-now)))
    (if (not l)
        (list (tutorial--div "wizard" 'text "Type C-h t to start the tutorial."))
        (let* ((slug (plist-get l 'slug))
               (steps (tutorial--steps l))
               (n (length steps))
               (i *tutorial-shown*)
               (step (and (< i n) (list-ref steps i)))
               (done? (and step (tutorial-step-done? slug i))))
          (list
            (tutorial--div "wizard tutorial-slide"
              'children
              (append
                (list (tutorial--div "tutorial-kicker"
                        'text (string-append "Lesson " (number->string (plist-get l 'n)) " of "
                                             (number->string (length (tutorial-lessons)))
                                             " - " (plist-get l 'title)))
                      (tutorial--div "tutorial-dots"
                        'children
                        (map (lambda (k)
                               (list 'tag "span" 'text ""
                                     'class (string-append "tutorial-dot"
                                                           (cond ((= k i) " tutorial-dot-here")
                                                                 ((tutorial-step-done? slug k) " tutorial-dot-done")
                                                                 (else "")))))
                             (iota n))))
                (if step
                    (list (tutorial--div "tutorial-say" 'segs (tutorial--say (car step)))
                          (tutorial--div "tutorial-state"
                            'text (cond (done? "Done. Press n for the next step.")
                                        ((or (pair? (cadr step)) (tutorial--await-of slug (car step)))
                                         "Do it in the practice pane. The slide moves on when you do.")
                                        (else "When you have done it, press n here, or ⌃C ⌃N in the practice page."))))
                    (list (tutorial--div "tutorial-say"
                            'segs (tutorial--say
                                    (if (= n 0)
                                        "Read this lesson in the lesson pane. Press n when you are ready to go on."
                                        "Every step of this lesson is done. Press n for the next lesson.")))))
                (if *tutorial-help* (list (tutorial--div "tutorial-help" 'text *tutorial-help*)) '())
                ;; the slide's keymap, d                ;; the keys are the window's keys bar, as every page has them
                '())))))))

(define (tutorial--slide-keys)
  (append '(("n" "next") ("p" "back") ("N" "next lesson") ("P" "previous lesson")
            ("i" "lessons"))
          (if (equal? *tutorial-current* "set-up") '(("h" "help")) '())
          '(("r" "restart lesson") ("R" "reset"))))

(define (tutorial--draw-detail!)
  (let ((buf *tutorial-detail-buffer*))
    (when (buffer-known? buf)
      (desktop-skip! buf 'render-blocks)
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'render-blocks (tutorial--detail-blocks))
      ;; the slide's keys, in the keys bar every page carries
      (buffer-set-local! buf 'footer-line-blocks
        (list (component 'ui/keys-bar (list 'main (tutorial--slide-keys))))))))

(define-mode "tutorial-detail-mode"
  (lambda ()
    (buffer-set-read-only! (current-buffer) #t)
    (tutorial--draw-detail!)))

(mode-keys! "tutorial-detail-mode"
  '(("n" "tutorial-next") ("RET" "tutorial-next") ("p" "tutorial-back")
    ("N" "tutorial-next-lesson") ("P" "tutorial-previous-lesson")
    ("i" "tutorial-index") ("h" "tutorial-help")
    ("r" "tutorial-restart-lesson") ("R" "tutorial-reset") ("q" "quit-window")))

(add-hook! (list 'block-click 'tutorial)
  (lambda (buf id)
    (and (equal? buf *tutorial-detail-buffer*)
         (let ((hit (assoc id '(("tutorial:next" "tutorial-next") ("tutorial:back" "tutorial-back")
                                ("tutorial:next-lesson" "tutorial-next-lesson")
                                ("tutorial:previous-lesson" "tutorial-previous-lesson")
                                ("tutorial:index" "tutorial-index") ("tutorial:help" "tutorial-help")
                                ("tutorial:restart" "tutorial-restart-lesson")
                                ("tutorial:reset" "tutorial-reset")))))
           (and hit (begin (run-command (cadr hit)) #t))))))

(define-style! 'tutorial "
.tutorial-slide { max-width: 36em; }
.tutorial-kicker { font-family: var(--font-mono); font-size: 12px; letter-spacing: .06em; text-transform: uppercase;
  color: var(--dim-fg); margin-bottom: 14px; }
.tutorial-dots { display: flex; gap: 7px; margin-bottom: 30px; }
.tutorial-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; border: 1px solid var(--border-bg); }
.tutorial-dot-done { background: var(--dim-fg); border-color: var(--dim-fg); }
.tutorial-dot-here { background: var(--accent-fg); border-color: var(--accent-fg); }
.tutorial-say { font-size: 26px; line-height: 1.45; margin-bottom: 18px; }
.tutorial-key { font-family: var(--font-mono); font-size: .82em; padding: 1px 7px; border: 1px solid var(--border-bg);
  border-radius: 4px; white-space: nowrap; }
.tutorial-state { font-size: 15px; color: var(--dim-fg); }
.tutorial-help { margin-top: 18px; padding: 12px 14px; font-size: 15px; border-left: 3px solid var(--warn-fg);
  background: color-mix(in srgb, var(--warn-fg) 10%, transparent); }
")

;;; the lesson and the practice page

(define (tutorial--fill! buf text mode)
  (buffer-set-read-only! buf #f)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-insert! buf 0 text)
  (unless (buffer-derived-mode? buf mode)
    (with-current-buffer buf (lambda () (set-mode! mode))))
  (buffer-goto! buf 0)
  (let ((w (window-showing buf))) (when w (window-set-point! w 0)))
  (buffer-mark-saved! buf))

(define (tutorial--reading-index l)
  ;; the reading of the step on the slide; past the last step, the last one
  (let* ((steps (tutorial--steps l))
         (rs (plist-get l 'readings))
         (i *tutorial-shown*))
    ;; a box right after a box has no reading of its own: the one before
    ;; it still stands
    (let back ((k (cond ((< i (length steps)) (caddr (list-ref steps i)))
                        (else (- (length rs) 1)))))
      (if (and (> k 0) (equal? (string-trim (list-ref rs k)) ""))
          (back (- k 1))
          k))))

(define (tutorial--draw-lesson! l)
  ;; the lesson is for reading: rendered, not for typing in, and only the
  ;; part that the step on the slide belongs to
  (let* ((buf *tutorial-lesson-buffer*)
         (k (tutorial--reading-index l))
         (key (list (plist-get l 'slug) k)))
    (unless (equal? (buffer-local buf 'tutorial-reading) key)
      (tutorial--fill! buf (string-append "# " (number->string (plist-get l 'n)) ". "
                                          (plist-get l 'title) "\n\n"
                                          (tutorial--symbolize (list-ref (plist-get l 'readings) k)) "\n")
                       "morg-mode")
      (unless (minor-mode-on? buf "preview-mode") (enable-minor-mode! buf "preview-mode"))
      (preview-heal! buf)
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'tutorial-reading key))))

(define (tutorial--practice-text l)
  ;; the lesson's prose, to move in and change; tables, Try it boxes and
  ;; headings stay in the lesson
  (let ((paras (filter (lambda (p)
                         (and (not (equal? p ""))
                              (not (string-prefix? "|" p)) (not (string-prefix? ">" p))
                              (not (string-prefix? "#" p)) (not (string-prefix? "```" p))))
                       (string-split (plist-get l 'body) "\n"))))
    (string-append "Practise here. This page is yours: move, type, kill and undo as you like.\n\n"
                   (tutorial--symbolize (string-join paras "\n\n")) "\n")))

(define (tutorial--fill-practice! l)
  (let ((buf *tutorial-buffer*))
    (unless (equal? (buffer-local buf 'tutorial-lesson) (plist-get l 'slug))
      (tutorial--fill! buf (tutorial--practice-text l) "tutorial-practice-mode")
      (buffer-set-local! buf 'footer-line-blocks
        (list (component 'ui/keys-bar
                (list 'main '(("⌃C ⌃N" "next") ("⌃C ⌃P" "back") ("⌃C ⌃L" "lessons"))))))
      (buffer-set-local! buf 'tutorial-lesson (plist-get l 'slug)))))

(define-derived-mode "tutorial-practice-mode" "text-mode" (lambda () #t))

(mode-keys! "tutorial-practice-mode"
  '(("C-c C-n" "tutorial-next") ("C-c C-p" "tutorial-back")
    ("C-c C-c" "tutorial-tick-step") ("C-c C-l" "tutorial-index") ("C-c C-h" "tutorial-help")))

;;; the panes

(define (tutorial--join! buf role)
  (when (buffer-exists? buf)
    (app-claim! buf *tutorial-app-id* role)
    (buffer-join-here! buf))
  buf)

(define (tutorial--ensure! name mode role)
  (unless (buffer-exists? name)
    (buffer-create name)
    (buffer-append! name "\n"))
  (unless (buffer-derived-mode? name mode)
    (with-current-buffer name (lambda () (set-mode! mode))))
  (tutorial--join! name role))

(define (tutorial--panes!)
  (list (tutorial--ensure! *tutorial-buffer* "tutorial-practice-mode" 'home)
        (tutorial--ensure! *tutorial-detail-buffer* "tutorial-detail-mode" 'detail)
        (tutorial--ensure! *tutorial-lesson-buffer* "morg-mode" 'detail)))

(define (tutorial--changed!)
  (tutorial--save!)
  (tutorial--arm!)
  (tutorial--draw-detail!)
  (let ((l (tutorial--lesson-now)))
    (when (and l (buffer-known? *tutorial-lesson-buffer*)) (tutorial--draw-lesson! l)))
  (when (buffer-known? *tutorial-index-buffer*) (list-refresh! *tutorial-index-buffer*)))

(define (tutorial--go! l)
  (set! *tutorial-current* (plist-get l 'slug))
  (set! *tutorial-shown* (or (tutorial--next-step l) 0))
  (set! *tutorial-help* #f)
  (when (= (tutorial--step-count l) 0) (tutorial--mark! (plist-get l 'slug) 0))
  (when (buffer-known? *tutorial-buffer*) (tutorial--fill-practice! l))
  (tutorial--changed!)
  l)

(define (tutorial--first-open)
  (or (find (lambda (l) (not (tutorial-lesson-done? l))) (tutorial-lessons))
      (car (tutorial-lessons))))

(define (tutorial-open!)
  "Open the tutorial: practice, slide and lesson, at the step the reader is on."
  (tutorial--load!)
  (let ((panes (tutorial--panes!)))
    (tutorial--go! (or (tutorial--lesson-now) (tutorial--first-open)))
    (panes-tile! 'columns panes)
    (let ((w (window-showing *tutorial-buffer*))) (when w (select-window! w)))
    *tutorial-buffer*))

(define (tutorial--manual? l i)
  (let ((step (list-ref (tutorial--steps l) i)))
    (and (null? (cadr step)) (not (tutorial--await-of (plist-get l 'slug) (car step))))))

(define (tutorial--move! dir)
  (let* ((l (tutorial--lesson-now))
         (to (and l (tutorial--nth (+ (plist-get l 'n) dir)))))
    (cond ((not l) (tutorial-open!))
          (to (tutorial--go! to) (message (string-append "Lesson " (number->string (plist-get to 'n))
                                                          ": " (plist-get to 'title))))
          (else (message (if (> dir 0) "This is the last lesson" "This is the first lesson"))))))

(define (tutorial-next!)
  "The next step; past the last step, the next lesson. A step with nothing to watch is done when you go past it."
  (let* ((l (tutorial--lesson-now))
         (n (if l (tutorial--step-count l) 0))
         (i *tutorial-shown*))
    (cond ((not l) (tutorial-open!))
          (else
            (when (and (< i n) (tutorial--manual? l i)) (tutorial--mark! (plist-get l 'slug) i))
            (if (< (+ i 1) n)
                (begin (set! *tutorial-shown* (+ i 1))
                       (set! *tutorial-help* #f)
                       (tutorial--changed!))
                (tutorial--move! 1))))))

(define (tutorial-back!)
  (cond ((> *tutorial-shown* 0)
         (set! *tutorial-shown* (- *tutorial-shown* 1))
         (set! *tutorial-help* #f)
         (tutorial--changed!))
        (else (tutorial--move! -1))))

(define (tutorial-tick-step!)
  (let ((l (tutorial--lesson-now)))
    (if (and l (< *tutorial-shown* (tutorial--step-count l)))
        (tutorial-step-done! (plist-get l 'slug) *tutorial-shown*)
        (message "No step to tick"))))

(define (tutorial-restart-lesson!)
  "Start the lesson on the slide again: no step done, a fresh practice page."
  (let ((l (tutorial--lesson-now)))
    (when l
      (set! *tutorial-done* (alist-put *tutorial-done* (plist-get l 'slug) '()))
      (when (buffer-known? *tutorial-buffer*) (buffer-set-local! *tutorial-buffer* 'tutorial-lesson #f))
      (tutorial--go! l)
      (message (string-append "Started again: " (plist-get l 'title))))))

(define (tutorial-reset!)
  (y-or-n "Forget all tutorial progress and start again?"
    (lambda ()
      (set! *tutorial-done* '())
      (set! *tutorial-current* #f)
      (for-each (lambda (b) (when (buffer-known? b) (buffer-set-local! b 'tutorial-lesson #f)))
                (list *tutorial-buffer*))
      (when (buffer-known? *tutorial-lesson-buffer*)
        (buffer-set-local! *tutorial-lesson-buffer* 'tutorial-reading #f))
      (tutorial--go! (car (tutorial-lessons)))
      (message "Tutorial progress reset"))
    (lambda () (message "Kept your progress"))))

;;; the index: over the practice pane, gone with q

(define (tutorial--cells buf l)
  (let ((n (tutorial--step-count l))
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

(define-list-mode! "tutorial-index-mode"
  (list
    'doc (string-append
           "The lessons of the Compos tutorial. RET goes to the lesson on this row, d marks "
           "it done or not done, R resets all progress, g redraws, / narrows, and q goes back "
           "to the practice page.")
    'buffer *tutorial-index-buffer*
    'transient #f
    'rows (lambda (buf) (tutorial-lessons))
    'key (lambda (buf l) (plist-get l 'slug))
    'columns (lambda (buf) (list (list "" 2) (list "#" 3) (list "steps" 6) (list "lesson" #f)))
    'cells tutorial--cells
    'title tutorial--title
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "go") ("d" "done") ("R" "reset") ("/" "filter") ("q" "back")))
    'keys '(("RET" "tutorial-index-visit") ("d" "tutorial-toggle-done")
            ("R" "tutorial-reset") ("g" "tutorial-refresh") ("q" "tutorial-index-quit"))))

(define (tutorial-show-index!)
  (tutorial--load!)
  (let* ((buf (tutorial--ensure! *tutorial-index-buffer* "tutorial-index-mode" 'list))
         (w (or (window-showing *tutorial-buffer*) (active-window)))
         (l (tutorial--lesson-now)))
    (window-set-buffer! w buf)
    (select-window! w)
    (list-refresh! buf)
    (when l (list-goto-index! buf (- (plist-get l 'n) 1)))
    buf))

(define (tutorial-index-quit!)
  (let ((w (or (window-showing *tutorial-index-buffer*) (active-window))))
    (window-set-buffer! w (tutorial--ensure! *tutorial-buffer* "tutorial-practice-mode" 'home))
    (select-window! w)))

(define (tutorial-toggle-done!)
  (let ((l (list-current *tutorial-index-buffer*)))
    (when l
      (let ((n (tutorial--step-count l)))
        (set! *tutorial-done*
              (alist-put *tutorial-done* (plist-get l 'slug)
                         (cond ((tutorial-lesson-done? l) '())
                               ((= n 0) (list 0))
                               (else (iota n)))))
        (tutorial--changed!)))))

;;; commands

;;;###autoload
(define-command "tutorial"
  "Open the Compos tutorial: practice, a slide that teaches, and the lesson to read"
  (lambda () (tutorial-open!)))

(define-command "help-with-tutorial" "Open the Compos tutorial at the step you are on"
  (lambda () (tutorial-open!)))

(define-command "tutorial-next" "Go to the next step of the tutorial"
  (lambda () (tutorial-next!)))

(define-command "tutorial-back" "Go to the previous step of the tutorial"
  (lambda () (tutorial-back!)))

(define-command "tutorial-next-lesson" "Go to the next lesson"
  (lambda () (tutorial--move! 1)))

(define-command "tutorial-previous-lesson" "Go to the previous lesson"
  (lambda () (tutorial--move! -1)))

(define-command "tutorial-tick-step" "Mark the step on the slide done"
  (lambda () (tutorial-tick-step!)))

(define-command "tutorial-index" "Show the list of lessons over the practice page"
  (lambda () (tutorial-show-index!)))

(define-command "tutorial-index-visit" "Go to the lesson on this row"
  (lambda ()
    (let ((l (list-current *tutorial-index-buffer*)))
      (tutorial-index-quit!)
      (when l (tutorial--go! l)))))

(define-command "tutorial-index-quit" "Put the practice page back"
  (lambda () (tutorial-index-quit!)))

(define-command "tutorial-toggle-done" "Mark the lesson on this row done, or not done"
  (lambda () (tutorial-toggle-done!)))

(define-command "tutorial-restart-lesson" "Start the lesson on the slide again"
  (lambda () (tutorial-restart-lesson!)))

(define-command "tutorial-reset" "Forget all tutorial progress"
  (lambda () (tutorial-reset!)))

(define-command "tutorial-refresh" "Redraw the list of lessons"
  (lambda () (list-refresh! *tutorial-index-buffer*)))

;; decide answers the test question with JEV when its key is set, else laya
(tutorial-probe! "set-up" "asks **decide** a test question"
  (lambda (pass fail)
    (if (not (boundp 'decide-async))
        (fail "decide is not loaded in this editor")
        (decide-async "The payment server is down and customers cannot pay."
          (list 'urgent (decide-noul "Is this message urgent?"))
          (lambda (r)
            (let ((usage (plist-get r 'usage)))
              (if (pair? (plist-get r 'answers))
                  (begin
                    (pass)
                    (message (string-append "decide answered with "
                                            (format "~a" (caddr usage)) " in "
                                            (number->string (cadddr usage)) " ms")))
                  (fail (string-append "No decision model answered. Set TYPESAFE_API_KEY for JEV, "
                                       "or set up laya and type M-x laya-server.")))))))))

;; the extension step finishes itself: at once when the extension is
;; already there, else when it attaches
(tutorial-await! "set-up" "extension connects"
  (lambda () (and (boundp 'browser-connected?) (browser-connected?))))

(add-hook! 'browser-attached-hook 'tutorial-recheck!)

;; typing a word puts the practice page in the editing state: that is the
;; step, and the reader is in the practice page, where n types an n
(tutorial-await! "typing-and-the-focus" "type a word"
  (lambda () (and (buffer-known? *tutorial-buffer*) (editing-state? *tutorial-buffer*))))

(add-hook! 'editing-state-hook (lambda (buf) (when (equal? buf *tutorial-buffer*) (tutorial-recheck!))))

;; Behind the Set up lesson, a chat troubleshoots. A step that fails, or h
;; on the slide, goes to it; its answer comes to the slide. The chat is
;; never shown: C-x b *setup-chat* reads it. *setup* is the welcome page.
(define *tutorial-setup-chat* "*setup-chat*")
(define *tutorial-setup-slug* #f)

(define (tutorial--setup-brief what)
  (string-append
    "You are the setup chat behind the Compos tutorial. The reader is on the Set up lesson: "
    "a chat model, JEV, laya and the browser extension. " what " "
    "Find the cause with the editor tools. Fix what you can without asking: settings, daemons, "
    "paths. Then reply in at most three short sentences for the reader: what was wrong, what you "
    "did, and what the reader must do now. Do not ask questions."))

(define (tutorial--setup-ask! text k)
  ;; TEXT to the setup chat, started without showing it; K gets the reply,
  ;; or #f when none comes
  (let ((sent (ignore-errors
                (lambda ()
                  (if (and *tutorial-setup-slug* (buffer-known? *tutorial-setup-chat*))
                      (agent-prompt! *tutorial-setup-slug* text)
                      (set! *tutorial-setup-slug*
                            (execute* text (list 'title *tutorial-setup-chat* 'notify #f))))
                  (subagent-wait (list *tutorial-setup-slug*)
                    (lambda (results)
                      (let ((s (and (pair? results) (plist-get (car results) 'text))))
                        (k (and (string? s) (not (equal? (string-trim s) "")) s)))))
                  #t))))
    (unless sent (k #f))))

(define (tutorial--setup-help! slug what)
  (when (equal? slug "set-up")
    (set! *tutorial-help* "The setup chat is looking into it...")
    (tutorial--draw-detail!)
    (tutorial--setup-ask! (tutorial--setup-brief what)
      (lambda (said)
        (when (equal? *tutorial-current* "set-up")
          (set! *tutorial-help* (or said "The setup chat gave no answer. Type M-x setup to choose another model."))
          (tutorial--draw-detail!))))))

;; the model step: the setup wizard chose one already, or the reader does
(tutorial-await! "set-up" "choose the model that new chats use"
  (lambda () (and (boundp 'setup-complete?) (setup-complete?))))

;; the reply step sends its own test, through the setup chat
(tutorial-probe! "set-up" "test message to the model"
  (lambda (pass fail)
    (tutorial--setup-ask!
      (tutorial--setup-brief "This is a test that the model answers. Reply with the one word: ready.")
      (lambda (said)
        (if said
            (pass)
            (fail "The model gave no reply. Type M-x setup to choose another model, or M-x setup-ai-guide to check its login."))))))

(add-hook! 'tutorial-trouble-hook
  (lambda (slug why) (tutorial--setup-help! slug (string-append "This step failed: " why))))

(define (tutorial-ask-help!)
  "Ask the setup chat about the step on the slide."
  (let* ((l (tutorial--lesson-now))
         (steps (if l (tutorial--steps l) '())))
    (if (not (and l (equal? (plist-get l 'slug) "set-up")))
        (message "The setup chat helps with the Set up lesson")
        (tutorial--setup-help! "set-up"
          (string-append "The reader asks for help with this step: "
                         (if (< *tutorial-shown* (length steps))
                             (car (list-ref steps *tutorial-shown*))
                             "the lesson as a whole"))))))

(define-command "tutorial-help" "Ask the setup chat about the step on the slide"
  (lambda () (tutorial-ask-help!)))

;; the steps are watched from the start, not only once C-h t is open
(ignore-errors (lambda () (tutorial--load!) (tutorial--arm!)))

(category! 'learning)
(public! 'training-document-path
  "(training-document-path) — the bundled immutable tutorial master")
(public! 'training-state-path
  "(training-state-path) — the reader's saved tutorial content and point")
(public! 'tutorial-lessons
  "(tutorial-lessons) — the tutorial's lessons in order: plists of slug, n, title, body and tries")
(public! 'tutorial-open!
  "(tutorial-open!) — open the three tutorial panes at the step the reader is on")
(public! 'tutorial-step-done!
  "(tutorial-step-done! SLUG I) — mark step I of lesson SLUG done; the slide moves on")
(public! 'tutorial-proof!
  "(tutorial-proof! COMMAND PROOF) — a step that runs COMMAND is done when PROOF calls its PASS")
(public! 'tutorial-await!
  "(tutorial-await! SLUG TEXT READY?) — the step of SLUG whose text has TEXT is done when READY? answers true")
(public! 'tutorial-recheck!
  "(tutorial-recheck!) — ask the step on the slide again; call it from the hook of what it waits for")
