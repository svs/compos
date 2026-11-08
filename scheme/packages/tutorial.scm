;;; tutorial.scm --- the learn-by-doing tutorial: C-h t.
;;;
;;; The master is the package's own tutorial/COMPOS.md. The lesson pane
;;; visits it in morg-mode, narrowed to the lesson: an edit there changes
;;; the bundled tutorial, and the slide redraws from the live text. C-h t
;;; opens it as an app: one row per lesson, each lesson a page the reader
;;; edits while reading it, and its Try it boxes the steps of a wizard.
;;; The single TUTORIAL buffer below stays for onboarding.scm and
;;; training.scm, which stage it beside a guide chat.

(domain! 'learning)
(effects! '(read write))

(define *training-tutorial-buffer* "TUTORIAL")

(define (training-document-path)
  "Return the tutorial master, tutorial/COMPOS.md of the tutorial package."
  (locate-library "tutorial/COMPOS.md"))

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
(define *tutorial-lessons-mtime* #f)
(define *tutorial-done* '())       ;; ((SLUG (N ...)) ...): the steps the reader finished
(define *tutorial-current* #f)     ;; the lesson on the slide
(define *tutorial-shown* 0)        ;; the step on the slide
(define *tutorial-steps* '())      ;; ((SLUG ((TEXT (COMMAND ...)) ...)) ...)
(define *tutorial-listening* '()) ;; ((SLUG STEP (COMMAND ...)) ...): every step of the lesson, listening
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

(define (tutorial--lesson title lines n at)
  ;; AT is the byte where the lesson's ## heading starts in the master
  (let ((lines (filter (lambda (l) (not (equal? l "---"))) (reverse lines))))
    (list 'slug (string-downcase (re-replace-all "[^A-Za-z0-9]+" title "-"))
          'n n 'title title 'at at
          'body (string-trim (string-join lines "\n"))
          'readings (tutorial--readings lines)
          ;; a step's heading is the ### heading above its Try it, or #f
          'heads (let loop ((ls lines) (h #f) (out '()))
                   (cond ((null? ls) (reverse out))
                         ((string-prefix? "### " (car ls))
                          (loop (cdr ls) (string-trim (substring-bytes (car ls) 4 (string-byte-length (car ls)))) out))
                         ((string-prefix? *tutorial-try* (car ls)) (loop (cdr ls) h (cons h out)))
                         (else (loop (cdr ls) h out))))
          'tries (map (lambda (l)
                        (string-trim (substring-bytes l (string-byte-length *tutorial-try*)
                                                      (string-byte-length l))))
                      (filter (lambda (l) (string-prefix? *tutorial-try* l)) lines)))))

(define (tutorial--parse text)
  ;; one lesson per ## section of the master, numbered from 1 in order;
  ;; Contents is the master's own map, not a lesson, and its numbers are these.
  ;; A # heading after the first ends the lessons: what follows is kept for
  ;; later, and the index and the slides do not show it. POS is the byte
  ;; where the line starts, AT the one of the lesson's heading
  (let loop ((lines (string-split text "\n")) (pos 0) (title #f) (at 0) (acc '()) (out '()))
    (let ((flush (lambda ()
                   (if (and title (not (equal? title "Contents")))
                       (cons (tutorial--lesson title acc (+ 1 (length out)) at) out)
                       out)))
          (next (lambda () (+ pos (string-byte-length (car lines)) 1))))
      (cond ((null? lines) (reverse (flush)))
            ((and (string-prefix? "# " (car lines)) (or title (pair? out)))
             (reverse (flush)))
            ((string-prefix? "## " (car lines))
             (loop (cdr lines) (next)
                   (string-trim (substring-bytes (car lines) 3 (string-byte-length (car lines))))
                   pos '() (flush)))
            (else (loop (cdr lines) (next) title at (cons (car lines) acc) out))))))

(define (tutorial--lesson-visits?)
  ;; #t while the lesson pane visits the master
  (and (buffer-known? *tutorial-lesson-buffer*)
       (equal? (buffer-path *tutorial-lesson-buffer*) (training-document-path))))

(define (tutorial-lessons)
  "The lessons of the master, in order: plists of slug, n, title, at, body and tries."
  ;; while the lesson pane visits the master, its live text is the master:
  ;; each edit parses it again, and the steps and the slide follow. Else the
  ;; file is, and a new mtime parses it again
  (let* ((buf *tutorial-lesson-buffer*)
         (live (tutorial--lesson-visits?))
         (key (if live
                  (list 'buffer (buffer-version buf))
                  (list 'file (file-mtime (training-document-path))))))
    (unless (and *tutorial-lessons* (equal? key *tutorial-lessons-mtime*))
      (let ((text (if live (buffer-text buf) (read-file (training-document-path)))))
        (unless text (error "The Compos tutorial master is missing"))
        (set! *tutorial-lessons* (tutorial--parse text))
        (set! *tutorial-lessons-mtime* key)
        (set! *tutorial-steps* '())))
    *tutorial-lessons*))

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
                         ;; as in focus, where the lessons type the window
                         ;; keys: editing binds s-<right> to end-of-line
                         (filter (lambda (m) (not (string-prefix? "editing-" m)))
                                 (buffer-keymaps *tutorial-buffer*))
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

(define *tutorial-just-done* #f)

(define (tutorial--arm!)
  ;; every step of the lesson listens for the whole tutorial, done or not:
  ;; a step runs when the reader does it, also again. Ahead of the slide only
  ;; the next step hears. A command partway through a step keeps its place
  (set! *tutorial-armed* #t)
  (let* ((l (tutorial--lesson-now))
         (slug (and l (plist-get l 'slug)))
         (steps (if l (tutorial--steps l) '())))
    (unless (and l (pair? *tutorial-listening*) (equal? (car (car *tutorial-listening*)) slug))
      (set! *tutorial-listening*
            (let loop ((ss steps) (i 0) (acc '()))
              (if (null? ss)
                  (reverse acc)
                  (loop (cdr ss) (+ i 1) (cons (list slug i (cadr (car ss))) acc))))))
    ;; the step on the slide: its check runs, and the slide says what is left
    (set! *tutorial-watch*
          (and l (< *tutorial-shown* (length steps))
               (list-ref *tutorial-listening* *tutorial-shown*)))
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

(define *tutorial-last-group* #f)   ;; the frame's group after the last command

(define (tutorial--after-command)
  ;; after a restart or a reload the first command arms the watch again
  (unless *tutorial-armed* (tutorial--load!) (tutorial--arm!))
  (let ((cmd (tutorial--ran)))
    (tutorial--saw! cmd)
    ;; a character typed in the practice page: the type-a-word step, also
    ;; when the page was in editing before
    (when (and (equal? cmd "self-insert-command") (equal? (current-buffer) *tutorial-buffer*))
      (tutorial--saw! "practice-typed"))
    ;; the frame came back to the tutorial's group: the come-back steps of
    ;; Groups. C-x g opens the prompt, and its RET makes the switch
    (let ((g (ignore-errors frame-group)))
      (when (and g (not (equal? g *tutorial-last-group*)))
        (set! *tutorial-last-group* g)
        (when (and (buffer-known? *tutorial-buffer*) (equal? g (buffer-group *tutorial-buffer*)))
          (tutorial--saw! "tutorial-group-entered"))))
    ;; a quit that ends a key sequence cancelled a prefix: C-x ESC
    (when (equal? cmd "keyboard-quit")
      (let ((keys (ignore-errors (lambda () (last-keys)))))
        (when (and (pair? keys) (pair? (cdr keys)))
          (tutorial--saw! "prefix-cancelled")))))
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
  ;; CMD ran, or a caret motion reads as it: every step that waits for it
  ;; hears it. A step that has all it waits for is done, and listens afresh
  (when (string? cmd)
    (let* ((l (tutorial--lesson-now))
           (steps (if l (tutorial--steps l) '()))
           ;; where the slide was when the key came: a step this key finishes
           ;; moves it, and must not let a later step hear the same key
           (shown *tutorial-shown*))
      (set! *tutorial-listening*
            (map (lambda (w)
                   ;; a step far ahead of the slide does not hear it: steps share
                   ;; keys, and the slide must not jump over the ones between
                   (if (or (not (member cmd (caddr w))) (> (cadr w) (+ shown 1)))
                       w
                       (let ((left (filter (lambda (c) (not (equal? c cmd))) (caddr w))))
                         (cond ((null? left)
                                (tutorial--prove! (car w) (cadr w))
                                (list (car w) (cadr w) (cadr (list-ref steps (cadr w)))))
                               (else
                                (when (equal? (cadr w) *tutorial-shown*)
                                  (message (string-append "Good. Still to do: " (string-join left ", "))))
                                (list (car w) (cadr w) left))))))
                 *tutorial-listening*))
      (when (and *tutorial-watch* (< *tutorial-shown* (length *tutorial-listening*)))
        (set! *tutorial-watch* (list-ref *tutorial-listening* *tutorial-shown*))))))

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
  "Finish every step of the lesson whose awaited thing is there."
  (let* ((l (tutorial--lesson-now)))
    (when l
      (let ((slug (plist-get l 'slug)))
        (let loop ((ss (tutorial--steps l)) (i 0))
          (when (pair? ss)
            (let ((a (tutorial--await-of slug (car (car ss)))))
              ;; a done step waits again only on the slide: the world that
              ;; finished it is still there, and must not finish it over and over
              (when (and a (<= i (+ *tutorial-shown* 1))
                         (or (not (tutorial-step-done? slug i)) (= i *tutorial-shown*))
                         (ignore-errors (caddr a)))
                (tutorial-step-done! slug i)))
            (loop (cdr ss) (+ i 1))))))))

(define (tutorial-step-done! slug i)
  "Mark step I of lesson SLUG done. On the slide, the slide stays and says
   that n goes on: you choose when to move. Anywhere else n is not at hand,
   so the slide goes on to the next step by itself. A done step the reader
   repeats is done again, and says so."
  (let ((l (tutorial-lesson slug)))
    (when l
      (let* ((again? (tutorial-step-done? slug i))
             (here? (equal? slug *tutorial-current*))
             (auto? (and here?
                         (not (equal? (window-buffer (active-window)) *tutorial-detail-buffer*))
                         (< (+ i 1) (tutorial--step-count l)))))
        ;; a done step repeated off the slide stays done, quietly; on the
        ;; slide it says so, once
        (unless (and again? (or (not (= i *tutorial-shown*))
                                (equal? *tutorial-just-done* (list slug i))))
          (tutorial--mark! slug i)
          (set! *tutorial-just-done* (list slug i))
          ;; a step done ahead of the slide brings the slide to it
          (when (and here? (> i *tutorial-shown*))
            (set! *tutorial-shown* i))
          (when auto? (set! *tutorial-shown* (+ i 1)))
          (set! *tutorial-help* #f)
          (tutorial--changed!)
          (message (cond (auto? (if again? "Done again" "Done"))
                         (again? "Done again. Press n for the next step")
                         ((not (tutorial-lesson-done? l)) "Done. Press n for the next step")
                         ((tutorial--nth (+ (plist-get l 'n) 1)) "Lesson done. Press n for the next lesson")
                         (else "You finished the tutorial"))))))))

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

(define (tutorial--prose text)
  ;; plain words, and **a name** in bold
  (let loop ((ps (string-split text "**")) (bold? #f) (out '()))
    (if (null? ps)
        (reverse out)
        (loop (cdr ps) (not bold?)
              (if (equal? (car ps) "")
                  out
                  (cons (list 'tag "span" 'class (if bold? "tutorial-strong" "tutorial-text") 'text (car ps)) out))))))

(define (tutorial--say text)
  ;; the slide's words: each key a keycap, the editor's c-action-key with a
  ;; box around it, one cap per key of a sequence; a name beside a key, such
  ;; as the command after M-x, is plain code
  (let loop ((parts (string-split text "`")) (code? #f) (out '()))
    (if (null? parts)
        (reverse out)
        (loop (cdr parts) (not code?)
              (cond ((equal? (car parts) "") out)
                    ((not code?) (append (reverse (tutorial--prose (car parts))) out))
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

(define (tutorial--done-text l i)
  (if (< (+ i 1) (tutorial--step-count l))
      "Done. Press `n` for the next step."
      "Lesson done. Press `n` for the next lesson."))

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
            (tutorial--div (string-append "wizard tutorial-slide " *tutorial-motion*)
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
                    (filter pair? (list (let ((h (list-ref (plist-get l 'heads) (caddr step))))
                                          (if h (tutorial--div "tutorial-title" 'text h) '()))
                          (tutorial--div "tutorial-say" 'children (tutorial--say (car step)))
                          (let* ((here (list slug i))
                                 (p (tutorial--probe-of slug (car step))))
                            (cond ((and p (not done?) (equal? *tutorial-probing* here))
                                   (tutorial--div "tutorial-state tutorial-busy"
                                     'text (string-append (tutorial--probe-label p) "...")))
                                  ((and p (not done?) (equal? *tutorial-probe-failed* here))
                                   (tutorial--div "tutorial-state tutorial-failed"
                                     'text "That did not work. Press t to try again."))
                                  (p (tutorial--div (if done? "tutorial-state tutorial-press tutorial-done" "tutorial-state")
                                       'children (tutorial--say (if done? (tutorial--done-text l i) "Press `t` to run the check."))))
                                  ((and (not done?) (not (tutorial--cards-of slug (car step)))
                                        (or (pair? (cadr step)) (tutorial--await-of slug (car step))))
                                   '())
                                  (else
                          (tutorial--div (cond (done? "tutorial-state tutorial-press tutorial-done")
                                               ((not (or (pair? (cadr step)) (tutorial--await-of slug (car step)) (tutorial--cards-of slug (car step))))
                                                "tutorial-state tutorial-press")
                                               (else "tutorial-state"))
                            'children (tutorial--say (cond (done? (tutorial--done-text l i))
                                        ((tutorial--cards-of slug (car step))
                                         "Choose one below. The slide moves on when you do.")
                                        (else "When you have done it, press `n` here, or `C-c C-n` in the practice page.")))))))))
                    (list (tutorial--div "tutorial-say"
                            'children (tutorial--say
                                    (if (= n 0)
                                        "Read this lesson in the lesson pane. Press n when you are ready to go on."
                                        "Every step of this lesson is done. Press n for the next lesson.")))))
                ;; the cards stay after the step is done: the text still points at them
                (let ((c (and step (tutorial--cards-of slug (car step)))))
                  (if c (or (ignore-errors (caddr c)) '()) '()))
                (if *tutorial-help* (list (tutorial--div "tutorial-help" 'text *tutorial-help*)) '())
                ;; the slide's keymap, d                ;; the keys are the window's keys bar, as every page has them
                '())))))))

(define (tutorial--slide-keys)
  (append '(("n" "next") ("p" "back") ("N" "next lesson") ("P" "previous lesson")
            ("i" "lessons"))
          (if (tutorial--setup-lesson? *tutorial-current*) '(("h" "help")) '())
          (let* ((l (tutorial--lesson-now))
                 (steps (if l (tutorial--steps l) '())))
            (if (and l (< *tutorial-shown* (length steps))
                     (tutorial--probe-of *tutorial-current* (car (list-ref steps *tutorial-shown*))))
                '(("t" "try again"))
                '()))
          '(("r" "restart lesson") ("R" "reset") ("⌥O" "chat") ("q" "close"))))

;; A new step slides in: from the right going on, from the left going back.
;; The page is patched, not rebuilt, so the slide flips between two
;; animations of the same motion, and a changed animation plays again.
(define *tutorial-drawn* #f)    ;; (LESSON-N STEP) last drawn
(define *tutorial-motion* "") ;; the slide's motion class

(define (tutorial--note-motion!)
  (let* ((l (tutorial--lesson-now))
         (here (and l (list (plist-get l 'n) *tutorial-shown*)))
         (was *tutorial-drawn*))
    (when (and here (not (equal? here was)))
      (let* ((back? (and was (or (< (car here) (car was))
                                 (and (= (car here) (car was)) (< (cadr here) (cadr was))))))
             (flip (if (string-suffix? "-a" *tutorial-motion*) "-b" "-a")))
        (set! *tutorial-motion* (string-append (if back? "tutorial-from-left" "tutorial-from-right") flip))
        (set! *tutorial-drawn* here)))))

(define (tutorial--draw-detail!)
  (tutorial--note-motion!)
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
(mode-doc! "tutorial-detail-mode" "One lesson of the tutorial. The page is read-only.")

;; ESC and C-g on the slide leave nothing: the slide is where the lesson
;; is. A quit clears a help note and stays. Without this, keyboard-quit ran
;; the slide's q, and the slide's window closed.
(mode-quit! "tutorial-detail-mode"
  (lambda (buf)
    (set! *tutorial-help* #f)
    (tutorial--draw-detail!)
    (message "Quit")
    #t))

(mode-keys! "tutorial-detail-mode"
  '(("n" "tutorial-next") ("RET" "tutorial-next") ("p" "tutorial-back")
    ("N" "tutorial-next-lesson") ("P" "tutorial-previous-lesson")
    ("i" "tutorial-index") ("h" "tutorial-help")
    ("r" "tutorial-restart-lesson") ("R" "tutorial-reset") ("t" "tutorial-retry") ("q" "tutorial-close")
    ("c" "tutorial-connectors")))

;; the slide's c: set up and test the models in M-x llm-connectors
(define-command "tutorial-connectors" "Set up and test the model connectors"
  (lambda () (run-command "llm-connectors")))

(add-hook! (list 'block-click 'tutorial)
  (lambda (buf id)
    (and (equal? buf *tutorial-detail-buffer*)
         (cond
           ;; model cards on a slide: a key added there redraws it
           ((setup-model-card-click! buf id (lambda () (tutorial-recheck!) (tutorial--draw-detail!)))
            (tutorial--draw-detail!) #t)
           (else
         (let ((hit (assoc id '(("tutorial:next" "tutorial-next") ("tutorial:back" "tutorial-back")
                                ("tutorial:next-lesson" "tutorial-next-lesson")
                                ("tutorial:previous-lesson" "tutorial-previous-lesson")
                                ("tutorial:index" "tutorial-index") ("tutorial:help" "tutorial-help")
                                ("tutorial:restart" "tutorial-restart-lesson")
                                ("tutorial:reset" "tutorial-reset")
                                ("tutorial:connectors" "tutorial-connectors")))))
           (and hit (begin (run-command (cadr hit)) #t))))))))

(define-style! 'tutorial "
.tutorial-slide { max-width: 36em; }
.tutorial-kicker { font-family: var(--font-mono); font-size: 12px; letter-spacing: .06em; text-transform: uppercase;
  color: var(--dim-fg); margin-bottom: 14px; }
.tutorial-dots { display: flex; gap: 7px; margin-bottom: 30px; }
.tutorial-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; border: 1px solid var(--border-bg); }
.tutorial-dot-done { background: var(--dim-fg); border-color: var(--dim-fg); }
.tutorial-dot-here { background: var(--accent-fg); border-color: var(--accent-fg); }
.tutorial-title { font-size: 18px; font-weight: var(--fw-semi); margin-bottom: 10px; }
.tutorial-say { font-size: 26px; line-height: 1.45; margin-bottom: 18px; }
/* a key is a keycap: the editor's key element in a box, one cap a key. The
   cap keeps the main text colour: --accent steps down in an inactive window,
   and the tutorial's panes are inactive while you practise */
.tutorial-slide c-action-key.tutorial-key { display: inline-block; text-indent: 0; font-size: .78em; line-height: 1.45;
  padding: 0 .42em; margin: 0 .12em; vertical-align: .08em; color: var(--default-fg);
  border: 1px solid color-mix(in srgb, var(--default-fg) 40%, transparent);
  border-bottom: 3px solid color-mix(in srgb, var(--default-fg) 30%, transparent);
  border-radius: 6px; background: color-mix(in srgb, var(--default-fg) 7%, var(--default-bg)); }
.tutorial-say .tutorial-code { font-family: var(--font-mono); font-size: .85em; }
/* morg draws `KEY`{:.key} with the face key: the same keycap. text-indent:
   0, or a list item's hanging indent pushes the key out of its own box */
c-text.f-key, code.key { display: inline-block; text-indent: 0; font-family: var(--font-mono); font-weight: var(--fw-semi);
  color: var(--default-fg); font-size: .82em; line-height: 1.45; padding: 0 .42em; margin: 0 .1em;
  border: 1px solid color-mix(in srgb, var(--default-fg) 40%, transparent);
  border-bottom: 3px solid color-mix(in srgb, var(--default-fg) 30%, transparent);
  border-radius: 6px; background: color-mix(in srgb, var(--default-fg) 7%, var(--default-bg)); white-space: nowrap; }
.tutorial-state { font-size: 15px; color: var(--dim-fg); }
.tutorial-strong { font-weight: 600; }
/* a step that waits for n says so plainly */
.tutorial-press { font-size: 17px; color: var(--default-fg); padding: 10px 14px; margin-top: 6px;
  border-left: 3px solid var(--accent-fg); background: color-mix(in srgb, var(--accent-fg) 8%, transparent); }
/* a step that is done: green, and n goes on */
.tutorial-done { border-left-color: var(--ok-fg); background: color-mix(in srgb, var(--ok-fg) 12%, transparent); }
/* a new step slides in; two names for each way, so a patched page plays it again */
.tutorial-from-right-a { animation: tutorial-in-right-a .5s ease-out; }
.tutorial-from-right-b { animation: tutorial-in-right-b .5s ease-out; }
.tutorial-from-left-a { animation: tutorial-in-left-a .5s ease-out; }
.tutorial-from-left-b { animation: tutorial-in-left-b .5s ease-out; }
@keyframes tutorial-in-right-a { from { transform: translateX(56px); opacity: 0; } to { transform: none; opacity: 1; } }
@keyframes tutorial-in-right-b { from { transform: translateX(56px); opacity: 0; } to { transform: none; opacity: 1; } }
@keyframes tutorial-in-left-a { from { transform: translateX(-56px); opacity: 0; } to { transform: none; opacity: 1; } }
@keyframes tutorial-in-left-b { from { transform: translateX(-56px); opacity: 0; } to { transform: none; opacity: 1; } }
@media (prefers-reduced-motion: reduce) { .tutorial-slide { animation: none !important; } }
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


(define (tutorial--visit-master! buf)
  ;; the lesson pane visits the master in morg-mode: the user is its author,
  ;; types in it and saves it with C-x C-s. The slide is its preview
  (let ((path (training-document-path)))
    (unless (equal? (buffer-path buf) path)
      (let ((text (read-file path)))
        (unless text (error "The Compos tutorial master is missing"))
        (tutorial--fill! buf text "morg-mode")
        ;; the bytes just read, so the save only binds the pane to the file;
        ;; the pane never read the file itself, and the write guard asks that
        (allow-one-write! path)
        (with-current-buffer buf (lambda () (buffer-save! path)))
        (unless (buffer-derived-mode? buf "morg-mode")
          (with-current-buffer buf (lambda () (set-mode! "morg-mode"))))
        (buffer-set-local! buf 'morg-narrow-anchor #f)))
    ;; the reader sees the lesson as a page, in preview
    (unless (minor-mode-on? buf "preview-mode") (enable-minor-mode! buf "preview-mode"))
    ;; eager: the slide follows an edit even while the pane is hidden
    (unless (buffer-local buf 'tutorial-master-watch)
      (desktop-skip! buf 'tutorial-master-watch)
      (buffer-set-local! buf 'tutorial-master-watch
        (on-change! buf (lambda (pos inserted deleted source)
                          (unless (equal? source "locals") (tutorial--edited!)))
                    'eager)))))

(define (tutorial--edited!)
  ;; an edit of the lesson pane: the slide and the steps it watches follow
  ;; the live text. The lesson is the one the pane is narrowed to, so a new
  ;; title keeps it
  (when (tutorial--lesson-visits?)
    (let* ((at (morg-narrow-anchor *tutorial-lesson-buffer*))
           (l (and at (find (lambda (l) (= (plist-get l 'at) at)) (tutorial-lessons)))))
      (when l (set! *tutorial-current* (plist-get l 'slug)))
      (tutorial--arm!)
      (tutorial--draw-detail!))))

(define (tutorial--draw-lesson! l)
  ;; the lesson pane shows the lesson's section of the master; a reader who
  ;; stands in it keeps their own place
  (let ((buf *tutorial-lesson-buffer*))
    (tutorial--visit-master! buf)
    (let ((at (plist-get l 'at)))
      (unless (equal? (morg-narrow-anchor buf) at)
        (buffer-set-local! buf 'morg-narrow-anchor at)
        (morg-apply-narrow! buf)
        (let ((w (window-showing buf)))
          (when (and w (not (equal? w (active-window))))
            (window-set-point! w at)))))))

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
(mode-doc! "tutorial-practice-mode" "The practice page of a tutorial lesson: edit it as you like. C-c C-n goes to the next lesson, C-c C-p back, C-c C-l to the lessons.")

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
  ;; a lesson opened again listens afresh, even where it is done
  (set! *tutorial-just-done* #f)
  (set! *tutorial-listening* '())
  (set! *tutorial-probe-failed* #f)
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

;; the tutorial owns its frame: three equal columns, practice, slide and
;; lesson, whatever the columns layout holds; reset-layout puts them back
(define-mode-layout! "tutorial-practice-mode"
  (list 'h (/ 1 3) 'self *tutorial-detail-buffer* *tutorial-lesson-buffer*))

(define (tutorial-open!)
  "Open the tutorial: practice, slide and lesson, at the step the reader is on.
   The slide has the focus: a new reader does not know buffers yet, and the
   slide says what to do and takes its keys."
  (tutorial--load!)
  (let ((panes (tutorial--panes!)))
    (tutorial--go! (or (tutorial--lesson-now) (tutorial--first-open)))
    (set! *tutorial-open* #t)
    (set! *tutorial-frame* (selected-frame))
    (tutorial--arrange! *tutorial-buffer*)
    (let ((w (window-showing *tutorial-detail-buffer*)))
      (when (and w (not (equal? w (active-window)))) (select-window! w)))
    *tutorial-buffer*))

;;; the layout: the tutorial keeps its panes
;; While the tutorial is open, its group shows the slide and the lesson
;; beside whatever the reader works in. A command that takes one of them
;; off the screen, C-x 1 or a kill, gets it back after the command; leaving
;; the group leaves them alone. q on the slide closes the tutorial and ends
;; this.
(define *tutorial-open* #f)
(define *tutorial-arranging* #f)
(define *tutorial-frame* #f)   ;; the frame C-h t opened it in; no other frame is touched

(define (tutorial--work-buffer)
  ;; what the reader works in: the selected window's buffer when it is not
  ;; the slide or the lesson, else the practice page
  (let ((b (window-buffer (active-window))))
    (if (and (string? b) (buffer-exists? b)
             (not (member b (list *tutorial-detail-buffer* *tutorial-lesson-buffer*)))
             (not (minibuffer-buffer? b)))
        b
        *tutorial-buffer*)))

(define (tutorial--arrange! work)
  ;; WORK takes the practice pane of the mode layout, the slide and the
  ;; lesson the other two
  (set! *tutorial-arranging* #t)
  (unwind-protect
    (lambda () (apply-layout! work (mode-layout "tutorial-practice-mode")))
    (lambda () (set! *tutorial-arranging* #f))))

(define (tutorial-close!)
  "Close the tutorial: the slide and the lesson leave the screen, and the layout is the reader's again."
  (set! *tutorial-open* #f)
  (with-selected-frame (or *tutorial-frame* (selected-frame))
    (lambda ()
      (for-each (lambda (b) (let ((w (window-showing b))) (when w (select-window! w) (delete-window!))))
                (list *tutorial-lesson-buffer* *tutorial-detail-buffer*))))
  (message "Tutorial closed. C-h t opens it where you were"))

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
            (set! *tutorial-just-done* #f)
            (if (< (+ i 1) n)
                (begin (set! *tutorial-shown* (+ i 1))
                       (set! *tutorial-help* #f)
                       (tutorial--changed!))
                (tutorial--move! 1))))))

(define (tutorial-back!)
  ;; the step gone back to is a repeat: it listens again
  (set! *tutorial-just-done* #f)
  (set! *tutorial-probe-failed* #f)
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
      (set! *tutorial-shown* 0)
      (set! *tutorial-probing* #f)
      (set! *tutorial-probe-failed* #f)
      (set! *tutorial-help* #f)
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
    ;; the index has its own mode, so the pane may show it in a new window:
    ;; the focus goes where it is
    (window-set-buffer! w buf)
    (select-window! (or (window-showing buf) w))
    (list-refresh! buf)
    (when l (list-goto-index! buf (- (plist-get l 'n) 1)))
    buf))

(define (tutorial-index-quit!)
  (let ((w (or (window-showing *tutorial-index-buffer*) (active-window))))
    (window-set-buffer! w (tutorial--ensure! *tutorial-buffer* "tutorial-practice-mode" 'home))
    (select-window! (or (window-showing *tutorial-buffer*) w))))

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
(define-key "help-map" "t" "help-with-tutorial")

(define-command "tutorial-close" "Close the tutorial; C-h t opens it again where you were"
  (lambda () (tutorial-close!)))

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


;; a chat sends with RET, which runs agent-send
(tutorial-step-event! "chat" "press `RET` to send it" "agent-send")
;; C-x g both leaves and comes back: a come-back step also waits until the
;; frame is in the tutorial's group again, so the leaving key does not end it
(tutorial-step-event! "groups" "Then come back" "tutorial-group-entered")
(tutorial-step-event! "groups" "to come back" "tutorial-group-entered")
(tutorial-step-event! "agents" "press `RET` to send it" "agent-send")

;; the prefix step of the kept Key notation lesson finishes when the prefix is cancelled
(tutorial-step-event! "key-notation" "Press `ESC` to cancel" "prefix-cancelled")

;; Cmd-C and Cmd-V reach Scheme as clipboard-copy and clipboard-paste!: a
;; step can listen for them with tutorial-step-event!
(advice-add! 'clipboard-copy 'after 'tutorial-hears-copy
  (lambda (&rest args) (tutorial--saw! "clipboard-copy")))
(advice-add! 'clipboard-paste! 'after 'tutorial-hears-paste
  (lambda (&rest args) (tutorial--saw! "clipboard-paste")))

;; the focus and editing steps hear what the reader does, not the state: a
;; practice page that was in editing before must not pass the type-a-word
;; step on its own, nor one in focus the stop-editing step
(tutorial-step-event! "window-navigation" "type a word" "practice-typed")
(tutorial-step-event! "window-navigation" "to stop editing" "editing-stopped")

(define (tutorial--hear-editing! buf)
  (when (equal? buf *tutorial-buffer*)
    (tutorial--saw! (if (editing-state? buf) "practice-typed" "editing-stopped"))))

(add-hook! 'editing-state-hook 'tutorial--hear-editing!)

;; Behind a setup lesson a chat troubleshoots. The setup wizard does the
;; setup now, so no lesson is one; the machinery stays for a lesson that needs it.
;; It is the slide's own chat, attached as every page's chat is: M-o on the
;; slide opens it. A step that fails, or h on the slide, goes to it; its
;; answer comes to the slide.
(define *tutorial-setup-chat* #f)
(define *tutorial-setup-lessons* '())

(define (tutorial--setup-lesson? slug)
  (and (member slug *tutorial-setup-lessons*) #t))

(mode-chat-title! "tutorial-detail-mode" "Tutorial setup")

(define (tutorial--setup-brief what)
  (string-append
    "You are the setup chat behind the Compos tutorial. The reader is on a setup lesson: "
    "the chat model, or JEV, laya and the browser extension. " what " "
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
  (when (tutorial--setup-lesson? slug)
    (set! *tutorial-help* "The setup chat is looking into it...")
    (tutorial--draw-detail!)
    (tutorial--setup-ask! (tutorial--setup-brief what)
      (lambda (said)
        (when (equal? *tutorial-current* slug)
          (set! *tutorial-help* (or said "The setup chat gave no answer. Type M-x llm-connectors to test the models and choose another."))
          (tutorial--draw-detail!))))))

(add-hook! 'tutorial-trouble-hook
  (lambda (slug why) (tutorial--setup-help! slug (string-append "This step failed: " why))))

(define (tutorial-ask-help!)
  "Ask the setup chat about the step on the slide."
  (let* ((l (tutorial--lesson-now))
         (steps (if l (tutorial--steps l) '())))
    (if (not (and l (tutorial--setup-lesson? (plist-get l 'slug))))
        (message "The setup wizard sets up the models: M-x setup")
        (tutorial--setup-help! (plist-get l 'slug)
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
  "(training-document-path) — the tutorial master, tutorial/COMPOS.md beside tutorial.scm")
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
