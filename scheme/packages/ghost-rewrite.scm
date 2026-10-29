;;; ghost-rewrite.scm --- Rewrite a passage as ghost text, the way Copilot completes.
;;;
;;; Select a passage, or stand in a paragraph, and write what you want in
;;; square brackets where you want it: "it doesn't need [a word like spars
;;; or beams]". C-c i asks for a few rewrites. The passage stays lit while
;;; they come; the first one shows as ghost text over it, M-n and M-p walk
;;; them, C-c i again asks for more, TAB takes the one shown and C-g lets
;;; them all go. Any edit to the buffer lets them go too.

(require 'writing)
(require 'content-scale)
(require 'chat-mode)

(domain! 'writing)
(effects! '(write external spend))

(defcustom 'ghost-rewrite-count 4
  "How many rewrites one ask brings back."
  'group 'writing 'type 'integer)

(defface! 'ghost-rewrite-gone 'decoration "line-through" 'priority 5)

;; the state, a buffer local: (START END OLD ALTS INDEX). START and END are
;; byte offsets of the lit passage, OLD its text, ALTS the rewrites so far.
(define (ghost-rewrite--state buf) (buffer-local buf 'ghost-rewrite))
(define (ghost-rewrite--set! buf st) (buffer-set-local! buf 'ghost-rewrite st))

;; the region, else the paragraph at point, without its closing newline
(define (ghost-rewrite--span buf)
  (let* ((span (if (mark)
                   (list (region-beginning) (region-end))
                   (let ((pt (buffer-point buf)))
                     (find (lambda (p) (and (<= (car p) pt) (<= pt (cadr p))))
                           (content-scale-paragraphs buf)))))
         (text (buffer-text buf)))
    (and span
         (let loop ((end (cadr span)))
           (cond ((<= end (car span)) #f)
                 ((equal? (substring-bytes text (- end 1) end) "\n") (loop (- end 1)))
                 (else (list (car span) end)))))))

(define (ghost-rewrite-prompt buf passage n)
  (string-append
    "You rewrite one passage of a document open in a text editor"
    (let ((mode (buffer-local buf 'mode-name)))
      (if mode (string-append " (" mode ")") ""))
    ". Text in single square brackets is the author's note to you, an "
    "instruction for that spot: do what it asks there, and leave no bracket "
    "or note in the result. A [[link]] or a [text](url) link is not a note. "
    "When the passage holds a note, keep every word outside the notes exactly "
    "as written, typos and all, and vary only what the notes ask for. With no "
    "note, make the passage clearer and more direct, in the author's voice "
    "and casing."
    "\n\nPassage:\n" passage
    "\n\nGive " (number->string n) " different rewrites of the whole passage, "
    "best first, each one a real alternative. Separate them with a line "
    "holding only =====. Reply with nothing else: no numbering, no "
    "commentary, no quotes and no code fences."))

(define (ghost-rewrite-parse reply)
  (filter (lambda (s) (not (equal? (string-trim s) "")))
          (map llm-rewrite-clean (string-split reply "====="))))

(define (ghost-rewrite--space? s i)
  (and (member (substring s i (+ i 1)) '(" " "\n" "\t")) #t))

;; (P OLD-END NEW-END) in characters: OLD[P..OLD-END] gives way to
;; NEW[P..NEW-END]. The cut falls on whitespace, so a word is never split.
(define (ghost-rewrite-diff old new)
  (let* ((lo (string-length old))
         (ln (string-length new))
         (same (lambda (i j) (equal? (substring old i (+ i 1)) (substring new j (+ j 1)))))
         (p (let loop ((i 0))
              (if (and (< i lo) (< i ln) (same i i)) (loop (+ i 1)) i)))
         (p (let back ((i p))
              (if (or (= i 0) (= i lo) (ghost-rewrite--space? old (- i 1))) i (back (- i 1)))))
         (s (let loop ((k 0))
              (if (and (< (+ p k) lo) (< (+ p k) ln) (same (- lo k 1) (- ln k 1)))
                  (loop (+ k 1))
                  k)))
         (s (let fwd ((k s))
              (if (or (= k 0) (ghost-rewrite--space? old (- lo k))) k (fwd (- k 1))))))
    (list p (- lo s) (- ln s))))

(define (ghost-rewrite--paint! buf)
  (let* ((st (ghost-rewrite--state buf))
         (start (car st)) (end (cadr st)) (old (caddr st))
         (alts (list-ref st 3)) (i (list-ref st 4))
         (lit (list start end "region")))
    (if (null? alts)
        (overlay-set! buf 'ghost-rewrite (list lit (chrome-after end " …" "dim")))
        (let* ((new (list-ref alts i))
               (d (ghost-rewrite-diff old new))
               (at (lambda (k) (+ start (string-byte-length (substring old 0 k)))))
               (gs (at (car d)))
               (ge (at (cadr d))))
          (overlay-set! buf 'ghost-rewrite
            (append (list lit)
                    (if (< gs ge) (list (list gs ge "ghost-rewrite-gone")) '())
                    (list (chrome-after ge (substring new (car d) (caddr d)) "dim"))))
          (message (string-append (number->string (+ i 1)) "/" (number->string (length alts))
                                  "  TAB takes it · M-n M-p walk · C-c i more · C-g lets go"))))))

(define (ghost-rewrite--dismiss! buf)
  (let ((w (buffer-local buf 'ghost-rewrite-watch)))
    (when w
      (remove-on-change! w)
      (buffer-set-local! buf 'ghost-rewrite-watch #f)))
  (ghost-rewrite--set! buf #f)
  (overlay-clear! buf 'ghost-rewrite)
  (disable-minor-mode! buf "ghost-rewrite-mode"))

(define *ghost-rewrite-runs* 0)

(define (ghost-rewrite--ask! buf)
  (let* ((st (ghost-rewrite--state buf))
         (run (buffer-local buf 'ghost-rewrite-run))
         (start (car st))
         (old (caddr st))
         (prompt (ghost-rewrite-prompt buf old ghost-rewrite-count))
         (land (lambda (reply)
                 (let ((now (and (buffer-exists? buf) (ghost-rewrite--state buf))))
                   ;; a reply for a run since let go is dropped
                   (when (and now (equal? (buffer-local buf 'ghost-rewrite-run) run))
                     (let ((alts (append (list-ref now 3) (ghost-rewrite-parse reply))))
                       (if (null? alts)
                           (begin (ghost-rewrite--dismiss! buf) (message "The model gave no rewrite"))
                           (begin (ghost-rewrite--set! buf (list start (cadr now) old alts (list-ref now 4)))
                                  (ghost-rewrite--paint! buf)))))))))
    (message "Rewriting…")
    (if (equal? writing-model "")
        (llm prompt land)
        (llm-with-model prompt writing-model land))))

(define (ghost-rewrite--start! buf)
  (let ((span (ghost-rewrite--span buf)))
    (if (not span)
        (message "Nothing to rewrite here: select a passage")
        (let ((start (car span)) (end (cadr span)))
          (set-mark! #f)
          (ghost-rewrite--dismiss! buf)
          (set! *ghost-rewrite-runs* (+ *ghost-rewrite-runs* 1))
          (buffer-set-local! buf 'ghost-rewrite-run *ghost-rewrite-runs*)
          (ghost-rewrite--set! buf (list start end (substring-bytes (buffer-text buf) start end) '() 0))
          (enable-minor-mode! buf "ghost-rewrite-mode")
          (ghost-rewrite--paint! buf)
          (buffer-set-local! buf 'ghost-rewrite-watch
            (on-change! buf (lambda (pos inserted deleted source) (ghost-rewrite--dismiss! buf))
              'eager))
          (ghost-rewrite--ask! buf)))))

(define (ghost-rewrite--step! buf delta)
  (let ((st (ghost-rewrite--state buf)))
    (if (or (not st) (null? (list-ref st 3)))
        (message "No rewrite yet")
        (let ((n (length (list-ref st 3))))
          (ghost-rewrite--set! buf (list (car st) (cadr st) (caddr st) (list-ref st 3)
                                         (modulo (+ (list-ref st 4) delta) n)))
          (ghost-rewrite--paint! buf)))))

(define (ghost-rewrite--accept! buf)
  (let ((st (ghost-rewrite--state buf)))
    (if (or (not st) (null? (list-ref st 3)))
        (message "No rewrite yet")
        (let ((start (car st))
              (end (cadr st))
              (new (list-ref (list-ref st 3) (list-ref st 4))))
          (ghost-rewrite--dismiss! buf)
          (buffer-replace-range! buf start (- end start) new)
          (buffer-goto! buf (+ start (string-byte-length new)))))))

(define-command "ghost-rewrite"
  "Rewrite the region, or the paragraph at point, as ghost text; [notes] in it say what to do. Again asks for more"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (ghost-rewrite--state buf)
          (ghost-rewrite--ask! buf)
          (ghost-rewrite--start! buf)))))

(define-command "ghost-rewrite-accept" "Take the rewrite shown"
  (lambda () (ghost-rewrite--accept! (current-buffer))))
(define-command "ghost-rewrite-next" "Show the next rewrite"
  (lambda () (ghost-rewrite--step! (current-buffer) 1)))
(define-command "ghost-rewrite-previous" "Show the previous rewrite"
  (lambda () (ghost-rewrite--step! (current-buffer) -1)))
(define-command "ghost-rewrite-quit" "Let the rewrites go"
  (lambda () (ghost-rewrite--dismiss! (current-buffer)) (message "Rewrites dropped")))

(register-minor-mode! "ghost-rewrite-mode" (lambda (b) #t) (lambda (b) #t))
(minor-mode-keys! "ghost-rewrite-mode"
  '(("TAB" "ghost-rewrite-accept")
    ("M-n" "ghost-rewrite-next")
    ("M-p" "ghost-rewrite-previous")
    ("C-g" "ghost-rewrite-quit")))
(mode-doc! "ghost-rewrite-mode"
  "Rewrites of the lit passage wait as ghost text. `TAB` takes the one shown, `M-n` and `M-p` walk them, `C-c i` asks for more, and `C-g` or any edit lets them go.")

(define-key "mode-specific-map" "i" "ghost-rewrite")
(catalog-meta! 'command "ghost-rewrite" 'domain 'writing 'effects '(write external spend))

(effects! '(pure))
(public! 'ghost-rewrite-diff "(ghost-rewrite-diff OLD NEW) — (P OLD-END NEW-END) in characters: OLD[P..OLD-END] gives way to NEW[P..NEW-END], cut on whitespace")
(public! 'ghost-rewrite-parse "(ghost-rewrite-parse REPLY) — the rewrites in a model reply, split on =====")
