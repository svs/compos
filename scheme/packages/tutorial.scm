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

;; A step can listen for something that is not a command: the browser's copy
;; and paste call Scheme straight, with no command. The step of lesson SLUG
;; whose text has TEXT hears EVENT as if a command of that name ran.
(define *tutorial-step-events* '())   ;; ((SLUG TEXT EVENT) ...)

(define (tutorial-step-event! slug text event)
  (set! *tutorial-step-events*
        (cons (list slug text event)
              (filter (lambda (e) (not (and (equal? (car e) slug) (equal? (cadr e) text))))
                      *tutorial-step-events*)))
  (set! *tutorial-steps* '())
  slug)

(define (tutorial--step-events slug text)
  (map caddr (filter (lambda (e) (and (equal? (car e) slug) (string-contains? text (cadr e))))
                     *tutorial-step-events*)))

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
                                  (append out (map (lambda (b)
                                                     (list (car b)
                                                           (append (cadr b) (tutorial--step-events slug (car b)))
                                                           k))
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
      (append (list (string-append "current " (or *tutorial-current* ""))
                    (string-append "shown " (number->string *tutorial-shown*)))
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
                    ((equal? (car ws) "shown")
                     (when (pair? (cdr ws)) (set! *tutorial-shown* (or (string->number (cadr ws)) 0))))
                    (else (set! *tutorial-done*
                                (alist-put *tutorial-done* (car ws)
                                           (map string->number (cdr ws))))))))
          (string-split raw "\n")))
      ;; an old save has no shown line: the first step not done
      (let ((l (tutorial--lesson-now)))
        (when (and l (not (and (string? raw) (string-contains? raw "\nshown "))))
          (set! *tutorial-shown* (or (tutorial--next-step l) 0)))))))

;;; watching the reader

(define (tutorial--arm!)
  (set! *tutorial-armed* #t)
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

(define *tutorial-armed* #f)   ;; the watch was set since this editor started

(define (tutorial--after-command)
  ;; after a restart or a reload the first command arms the watch again
  (unless *tutorial-armed* (tutorial--load!) (tutorial--arm!))
  (tutorial--saw! (tutorial--ran))
  (when (equal? (current-buffer) *tutorial-buffer*)
    (set! *tutorial-practice-at* (tutorial--where *tutorial-buffer*))))

;; In the editing state the browser moves the caret itself: no command runs,
;; and point-motion-hook says where point went. The motion reads as the
;; command a key would have run: a line down is next-line, the end of the
;; line is end-of-line.
(define *tutorial-practice-at* #f)   ;; (LINE COL POS EOL? END?) after the last move

(define (tutorial--where buf)
  (let* ((t (buffer-text buf))
         (n (string-byte-length t))
         (p (min (buffer-point buf) n))
         (lines (string-split (substring-bytes t 0 p) "\n"))
         (rest (substring-bytes t p n)))
    (list (length lines) (string-byte-length (last lines)) p
          (or (equal? rest "") (string-prefix? "\n" rest)) (= p n))))

(define (tutorial--motions a b)
  (let ((dl (- (car b) (car a)))
        (dc (- (cadr b) (cadr a))))
    (append
      (cond ((>= dl 5) '("scroll-up-command" "next-line"))
            ((> dl 0) '("next-line"))
            ((<= dl -5) '("scroll-down-command" "previous-line"))
            ((< dl 0) '("previous-line"))
            ((and (= (cadr b) 0) (> (cadr a) 0)) '("beginning-of-line"))
            ((and (list-ref b 3) (not (list-ref a 3))) '("end-of-line"))
            ((= dc 1) '("forward-char"))
            ((= dc -1) '("backward-char"))
            ((> dc 1) '("forward-word"))
            ((< dc -1) '("backward-word"))
            (else '()))
      (cond ((= (caddr b) 0) '("beginning-of-buffer"))
            ((list-ref b 4) '("end-of-buffer"))
            (else '())))))

(define (tutorial--point-moved buf)
  (when (equal? buf *tutorial-buffer*)
    (unless *tutorial-armed* (tutorial--load!) (tutorial--arm!))
    (let ((now (tutorial--where buf))
          (was *tutorial-practice-at*))
      (set! *tutorial-practice-at* now)
      (when was
        (for-each tutorial--saw! (tutorial--motions was now))))))

(add-hook! 'point-motion-hook 'tutorial--point-moved)

(define (tutorial--saw! cmd)
  ;; CMD ran, or a caret motion reads as it: the step on the slide hears it
  (let ((w *tutorial-watch*))
    (when w
        (when (and (string? cmd) (member cmd (caddr w)))
          (let ((left (filter (lambda (c) (not (equal? c cmd))) (caddr w))))
            (set! *tutorial-watch* (list (car w) (cadr w) left))
            (if (null? left)
                (tutorial--prove! (car w) (cadr w))
                (message (string-append "Good. Still to do: " (string-join left ", ")))))))))

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
(define *tutorial-probes* '())   ;; ((SLUG TEXT PROBE LABEL) ...)
(define *tutorial-probing* #f)   ;; (SLUG STEP) while a probe runs
(define *tutorial-probe-failed* #f)   ;; (SLUG STEP) after a probe failed

;; LABEL, a string or a thunk, says on the slide what the probe waits for
(define (tutorial-probe! slug text probe &optional label)
  (set! *tutorial-probes*
        (cons (list slug text probe (or label "Checking"))
              (filter (lambda (p) (not (and (equal? (car p) slug) (equal? (cadr p) text))))
                      *tutorial-probes*)))
  slug)

;; A step that shows cards on the slide: the step of lesson SLUG whose text
;; has TEXT draws the blocks FN answers, under the step, until it is done.
(define *tutorial-cards* '())   ;; ((SLUG TEXT FN) ...)

(define (tutorial-cards! slug text fn)
  (set! *tutorial-cards*
        (cons (list slug text fn)
              (filter (lambda (c) (not (and (equal? (car c) slug) (equal? (cadr c) text))))
                      *tutorial-cards*)))
  slug)

(define (tutorial--cards-of slug text)
  (and text (find (lambda (c) (and (equal? (car c) slug) (string-contains? text (cadr c))))
                  *tutorial-cards*)))

(define (tutorial--probe-of slug text)
  (and text (find (lambda (p) (and (equal? (car p) slug) (string-contains? text (cadr p))))
                  *tutorial-probes*)))

(define (tutorial--probe-label p)
  (let ((label (cadddr p))) (if (procedure? label) (label) label)))

(define (tutorial--probe!)
  ;; a failed probe waits for t: it does not run again on every redraw
  (let* ((w *tutorial-watch*)
         (l (and w (tutorial-lesson (car w))))
         (text (and l (car (list-ref (tutorial--steps l) (cadr w)))))
         (p (and w (tutorial--probe-of (car w) text)))
         (here (and w (list (car w) (cadr w)))))
    (when (and p (not (equal? *tutorial-probing* here)) (not (equal? *tutorial-probe-failed* here)))
      (let ((slug (car w)) (i (cadr w)))
        (set! *tutorial-probing* here)
        (tutorial--draw-detail!)
        ((caddr p)
         (lambda ()
           (set! *tutorial-probing* #f)
           (set! *tutorial-probe-failed* #f)
           (tutorial-step-done! slug i))
         (lambda (why)
           (set! *tutorial-probing* #f)
           (set! *tutorial-probe-failed* here)
           (tutorial--trouble! why)))))))

(define (tutorial-retry!)
  "Run the check of the step on the slide again."
  (set! *tutorial-probe-failed* #f)
  (set! *tutorial-help* #f)
  (tutorial--arm!)
  (unless *tutorial-probing* (tutorial--draw-detail!)))

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
    ;; a laptop keyboard has no Home, End, PageUp or PageDown: fn and an arrow
    ("<home>" "fn ←") ("<end>" "fn →") ("<prior>" "fn ↑") ("<next>" "fn ↓")))

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
  ;; the slide's words: each key a keycap, the editor's c-action-key with a
  ;; box around it, one cap per key of a sequence; a name beside a key, such
  ;; as the command after M-x, is plain code
  (let loop ((parts (string-split text "`")) (code? #f) (out '()))
    (if (null? parts)
        (reverse out)
        (loop (cdr parts) (not code?)
              (cond ((equal? (car parts) "") out)
                    ((not code?) (cons (list 'tag "span" 'class "tutorial-text" 'text (car parts)) out))
                    (else
                      (let ((tokens (string-split (car parts) " ")))
                        (if (tutorial--key-label (car tokens))
                            (append (reverse
                                      (map (lambda (t)
                                             (let ((cap (tutorial--key-label t)))
                                               (if cap
                                                   (list 'tag "c-action-key" 'class "tutorial-key" 'text cap)
                                                   (list 'tag "span" 'class "tutorial-code" 'text t))))
                                           tokens))
                                    out)
                            (cons (list 'tag "span" 'class "tutorial-code" 'text (car parts)) out)))))))))

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
                    (list (tutorial--div "tutorial-say" 'children (tutorial--say (car step)))
                          (let* ((here (list slug i))
                                 (p (tutorial--probe-of slug (car step))))
                            (cond ((and p (not done?) (equal? *tutorial-probing* here))
                                   (tutorial--div "tutorial-state tutorial-busy"
                                     'text (string-append (tutorial--probe-label p) "...")))
                                  ((and p (not done?) (equal? *tutorial-probe-failed* here))
                                   (tutorial--div "tutorial-state tutorial-failed"
                                     'text "That did not work. Press t to try again."))
                                  (p (tutorial--div "tutorial-state"
                                       'text (if done? "Done. Press n for the next step." "Press t to run the check.")))
                                  (else
                          (tutorial--div "tutorial-state"
                            'text (cond (done? "Done. Press n for the next step.")
                                        ((tutorial--cards-of slug (car step))
                                         "Choose one below. The slide moves on when you do.")
                                        ((or (pair? (cadr step)) (tutorial--await-of slug (car step)))
                                         "Do it in the practice pane. The slide moves on when you do.")
                                        (else "When you have done it, press n here, or ⌃C ⌃N in the practice page.")))))))
                    (list (tutorial--div "tutorial-say"
                            'children (tutorial--say
                                    (if (= n 0)
                                        "Read this lesson in the lesson pane. Press n when you are ready to go on."
                                        "Every step of this lesson is done. Press n for the next lesson.")))))
                (let ((c (and step (not done?) (tutorial--cards-of slug (car step)))))
                  (if c (or (ignore-errors (caddr c)) '()) '()))
                (if *tutorial-help* (list (tutorial--div "tutorial-help" 'text *tutorial-help*)) '())
                ;; the slide's keymap, d                ;; the keys are the window's keys bar, as every page has them
                '())))))))

(define (tutorial--slide-keys)
  (append '(("n" "next") ("p" "back") ("N" "next lesson") ("P" "previous lesson")
            ("i" "lessons"))
          (if (equal? *tutorial-current* "set-up") '(("h" "help")) '())
          (let* ((l (tutorial--lesson-now))
                 (steps (if l (tutorial--steps l) '())))
            (if (and l (< *tutorial-shown* (length steps))
                     (tutorial--probe-of *tutorial-current* (car (list-ref steps *tutorial-shown*))))
                '(("t" "try again"))
                '()))
          '(("r" "restart lesson") ("R" "reset") ("⌥O" "chat"))))

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
    ("r" "tutorial-restart-lesson") ("R" "tutorial-reset") ("t" "tutorial-retry") ("q" "quit-window")))

(add-hook! (list 'block-click 'tutorial)
  (lambda (buf id)
    (and (equal? buf *tutorial-detail-buffer*)
         (cond
           ((string-prefix? "wizard:use:" id) (tutorial--use-model! (substring id 11 (string-length id))) #t)
           ((string-prefix? "wizard:key:" id) (tutorial--add-key! (substring id 11 (string-length id))) #t)
           ((string-prefix? "wizard:install:" id)
            (let ((name (substring id 15 (string-length id))))
              (tutorial--use-model! name)
              (setup-install-agent! name))
            #t)
           (else
         (let ((hit (assoc id '(("tutorial:next" "tutorial-next") ("tutorial:back" "tutorial-back")
                                ("tutorial:next-lesson" "tutorial-next-lesson")
                                ("tutorial:previous-lesson" "tutorial-previous-lesson")
                                ("tutorial:index" "tutorial-index") ("tutorial:help" "tutorial-help")
                                ("tutorial:restart" "tutorial-restart-lesson")
                                ("tutorial:reset" "tutorial-reset")))))
           (and hit (begin (run-command (cadr hit)) #t))))))))

(define-style! 'tutorial "
.tutorial-slide { max-width: 36em; }
.tutorial-kicker { font-family: var(--font-mono); font-size: 12px; letter-spacing: .06em; text-transform: uppercase;
  color: var(--dim-fg); margin-bottom: 14px; }
.tutorial-dots { display: flex; gap: 7px; margin-bottom: 30px; }
.tutorial-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; border: 1px solid var(--border-bg); }
.tutorial-dot-done { background: var(--dim-fg); border-color: var(--dim-fg); }
.tutorial-dot-here { background: var(--accent-fg); border-color: var(--accent-fg); }
.tutorial-say { font-size: 26px; line-height: 1.45; margin-bottom: 18px; }
/* a key is a keycap: the editor's key element in a box, one cap a key */
.tutorial-say c-action-key.tutorial-key { display: inline-block; font-size: .78em; line-height: 1.45;
  padding: 0 .42em; margin: 0 .12em; vertical-align: .08em; border: 1px solid var(--border-bg);
  border-bottom-width: 3px; border-radius: 6px; background: var(--hl-line-bg); }
.tutorial-say .tutorial-code { font-family: var(--font-mono); font-size: .85em; }
.tutorial-state { font-size: 15px; color: var(--dim-fg); }
.tutorial-busy::before { content: \"\"; display: inline-block; width: 10px; height: 10px; margin-right: 9px;
  vertical-align: -1px; border: 2px solid var(--dim-fg); border-top-color: transparent; border-radius: 50%;
  animation: tutorial-spin .8s linear infinite; }
@keyframes tutorial-spin { to { transform: rotate(360deg); } }
.tutorial-failed { color: var(--warn-fg); }
/* the tutorial's panes are narrow by design, and their keys are the lesson:
   the keys bar stays, and wraps, where other windows hide it */
@container (max-width: 520px) { .window.tutorial-pane .buffer-footer:has(.c-keys-bar) { display: flex; } }
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

(define *tutorial-doc* #f)   ;; (LESSONS TEXT STARTS): the whole tutorial to read

(define (tutorial--doc)
  ;; every lesson, one after the other, so the lesson pane always has more to
  ;; read ahead. STARTS is ((SLUG K) BYTE): where reading K of a lesson begins.
  (let ((ls (tutorial-lessons)))
    (unless (and *tutorial-doc* (eq? (car *tutorial-doc*) ls))
      (let loop ((ls2 ls) (text "") (starts '()))
        (if (null? ls2)
            (set! *tutorial-doc* (list ls text (reverse starts)))
            (let* ((l (car ls2))
                   (head (string-append (if (equal? text "") "" "\n\n")
                                        "# " (number->string (plist-get l 'n)) ". " (plist-get l 'title) "\n\n"))
                   (top (string-byte-length text)))
              (let rloop ((rs (map tutorial--symbolize (plist-get l 'readings))) (k 0)
                          (acc (string-append text head)) (st starts))
                (if (null? rs)
                    (loop (cdr ls2) acc st)
                    (rloop (cdr rs) (+ k 1)
                           (string-append acc (if (= k 0) "" "\n\n") (car rs))
                           (cons (list (list (plist-get l 'slug) k)
                                       (if (= k 0) top (+ (string-byte-length acc) 2)))
                                 st))))))))
    *tutorial-doc*))

(define (tutorial--draw-lesson! l)
  ;; the lesson pane is for reading: rendered, not for typing in. It holds the
  ;; whole tutorial, and each step turns it to the part the step belongs to.
  (let* ((buf *tutorial-lesson-buffer*)
         (doc (tutorial--doc))
         (k (tutorial--reading-index l))
         (key (list (plist-get l 'slug) k)))
    (unless (equal? (buffer-local buf 'tutorial-lesson) "all")
      (tutorial--fill! buf (string-append (cadr doc) "\n") "morg-mode")
      (unless (minor-mode-on? buf "preview-mode") (enable-minor-mode! buf "preview-mode"))
      (preview-heal! buf)
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'tutorial-lesson "all")
      (buffer-set-local! buf 'tutorial-reading #f))
    (unless (equal? (buffer-local buf 'tutorial-reading) key)
      (buffer-set-local! buf 'tutorial-reading key)
      ;; the lesson's window turns to the step's part; a reader who stands
      ;; in the lesson keeps their own place
      (let ((w (window-showing buf))
            (hit (assoc key (caddr doc))))
        (when (and w hit (not (equal? w (active-window))))
          (window-set-point! w (cadr hit))
          (buffer-windows-follow-point! buf))))))

(define (tutorial--practice-text l)
  ;; the lesson's prose, to move in and change; tables, Try it boxes and
  ;; headings stay in the lesson
  (let ((paras (filter (lambda (p)
                         (and (not (equal? p ""))
                              (not (string-prefix? "|" p)) (not (string-prefix? ">" p))
                              (not (string-prefix? "#" p)) (not (string-prefix? "```" p))))
                       (string-split (plist-get l 'body) "\n"))))
    (string-append (tutorial--symbolize (string-join paras "\n\n")) "\n")))

(define (tutorial--fill-practice! l)
  ;; the practice page holds the lesson's own prose, and a new lesson gives
  ;; it a fresh page
  (let ((buf *tutorial-buffer*))
    (unless (equal? (buffer-local buf 'tutorial-lesson) (plist-get l 'slug))
      (tutorial--fill! buf (string-append "Practise here. This page is yours: move, type, kill and undo as you like.\n\n"
                                          (tutorial--practice-text l))
                       "tutorial-practice-mode")
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

(define (tutorial--mark-pane! buf)
  ;; tutorial-pane keeps the keys bar in a narrow window
  (let ((cs (string-split (or (buffer-local buf 'window-class) "") " ")))
    (unless (member "tutorial-pane" cs)
      (buffer-set-local! buf 'window-class
        (string-join (filter (lambda (c) (not (equal? c ""))) (append cs (list "tutorial-pane"))) " "))))
  buf)

(define (tutorial--panes!)
  (list (tutorial--mark-pane! (tutorial--ensure! *tutorial-buffer* "tutorial-practice-mode" 'home))
        (tutorial--mark-pane! (tutorial--ensure! *tutorial-detail-buffer* "tutorial-detail-mode" 'detail))
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
  ;; a step done by hand: it watches no command, waits for nothing, and runs
  ;; no check
  (let ((step (list-ref (tutorial--steps l) i)))
    (and (null? (cadr step))
         (not (tutorial--await-of (plist-get l 'slug) (car step)))
         (not (tutorial--probe-of (plist-get l 'slug) (car step))))))

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
        (buffer-set-local! *tutorial-lesson-buffer* 'tutorial-lesson #f))
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

(define-command "tutorial-retry" "Run the check of the step on the slide again"
  (lambda () (tutorial-retry!)))

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
                                       "or set up laya and type M-x laya-server.")))))
          ;; an answer comes in well under a second; five seconds is a hang
          'timeout 5)))
  (lambda ()
    (string-append "Asking "
                   (if (and (boundp 'decide--first-live) (ignore-errors decide--first-live))
                       (format "~a" (decide--first-live))
                       "decide")
                   " a test question")))

;; the extension step finishes itself: at once when the extension is
;; already there, else when it attaches
(tutorial-await! "set-up" "extension connects"
  (lambda () (and (boundp 'browser-connected?) (browser-connected?))))

(add-hook! 'browser-attached-hook 'tutorial-recheck!)

;; Cmd-C and Cmd-V reach Scheme as clipboard-copy and clipboard-paste!
(tutorial-step-event! "selecting-copying-and-pasting" "Copy them with Cmd-C" "clipboard-copy")
(tutorial-step-event! "selecting-copying-and-pasting" "paste with Cmd-V" "clipboard-paste")
(advice-add! 'clipboard-copy 'after 'tutorial-hears-copy
  (lambda (&rest args) (tutorial--saw! "clipboard-copy")))
(advice-add! 'clipboard-paste! 'after 'tutorial-hears-paste
  (lambda (&rest args) (tutorial--saw! "clipboard-paste")))

;; typing a word puts the practice page in the editing state: that is the
;; step, and the reader is in the practice page, where n types an n
(tutorial-await! "typing-and-the-focus" "type a word"
  (lambda () (and (buffer-known? *tutorial-buffer*) (editing-state? *tutorial-buffer*))))

(add-hook! 'editing-state-hook (lambda (buf) (when (equal? buf *tutorial-buffer*) (tutorial-recheck!))))

;; Behind the Set up lesson, a chat troubleshoots. It is the slide's own
;; chat, attached as every page's chat is: M-o on the slide opens it. A step
;; that fails, or h on the slide, goes to it; its answer comes to the slide.
(define *tutorial-setup-chat* #f)

(mode-chat-title! "tutorial-detail-mode" "Tutorial setup")

(define (tutorial--setup-brief what)
  (string-append
    "You are the setup chat behind the Compos tutorial. The reader is on the Set up lesson: "
    "a chat model, JEV, laya and the browser extension. " what " "
    "Find the cause with the editor tools. Fix what you can without asking: settings, daemons, "
    "paths. Then reply in at most three short sentences for the reader: what was wrong, what you "
    "did, and what the reader must do now. Do not ask questions."))

(define (tutorial--setup-ask! text k)
  ;; TEXT to the slide's own chat, made quietly when it has none; K gets the
  ;; reply, or #f when none comes
  (let ((chat (ignore-errors (lambda () (page-chat! *tutorial-detail-buffer* text)))))
    (if (not chat)
        (k #f)
        (begin
          (set! *tutorial-setup-chat* chat)
          (subagent-wait (list chat)
            (lambda (results)
              (let ((s (and (pair? results) (plist-get (car results) 'text))))
                (k (and (string? s) (not (equal? (string-trim s) "")) s)))))))))

(define (tutorial--setup-help! slug what)
  (when (equal? slug "set-up")
    (set! *tutorial-help* "The setup chat is looking into it...")
    (tutorial--draw-detail!)
    (tutorial--setup-ask! (tutorial--setup-brief what)
      (lambda (said)
        (when (equal? *tutorial-current* "set-up")
          (set! *tutorial-help* (or said "The setup chat gave no answer. Type M-x setup to choose another model."))
          (tutorial--draw-detail!))))))

;; the model step: the setup wizard chose one already, or the reader does,
;; on the slide, from the same cards *Setup* shows; the step finishes when a
;; model is in use
(tutorial-await! "set-up" "choose the model that new chats use"
  (lambda () (and (boundp 'setup-complete?) (setup-complete?))))

(tutorial-cards! "set-up" "choose the model that new chats use"
  (lambda ()
    (if (boundp 'setup-inference-scan)
        (list (tutorial--div "wizard-grid" 'children (map setup-wizard--card (setup-inference-scan))))
        '())))

(define (tutorial--use-model! name)
  "New chats use the connector NAME; the model step finishes."
  (customize-save! 'setup-default-connector name)
  (set! *default-connector* name)
  (setup--save-default! name)
  (message (string-append "New chats use " name))
  (tutorial-recheck!)
  (tutorial--draw-detail!))

(define (tutorial--add-key! name)
  ;; the card's key, asked as *Setup* asks it; the slide redraws when it is in
  (setup-wizard-add-key! *tutorial-detail-buffer* name
    (lambda () (tutorial-recheck!) (tutorial--draw-detail!))))

;; the reply step sends its own test, through the setup chat
(tutorial-probe! "set-up" "test message to the model"
  (lambda (pass fail)
    (tutorial--setup-ask!
      (tutorial--setup-brief "This is a test that the model answers. Reply with the one word: ready.")
      (lambda (said)
        (if said
            (pass)
            (fail "The model gave no reply. Type M-x setup to choose another model, or M-x setup-ai-guide to check its login.")))))
  (lambda () (string-append "Waiting for a reply from " *default-connector*)))

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
