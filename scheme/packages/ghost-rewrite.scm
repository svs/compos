;;; ghost-rewrite.scm --- Rewrite a passage as ghost text, the way Copilot completes.
;;;
;;; Select a passage, or stand in a paragraph, and write what you want in
;;; square brackets where you want it: "it doesn't need [a word like spars
;;; or beams]". C-c i asks for a few rewrites. The passage stays lit while
;;; they come; the first one shows as ghost text over it, M-n and M-p walk
;;; them, C-c i again asks for more, TAB takes the one shown and C-g lets
;;; them all go. Any edit to the buffer lets them go too.
;;;
;;; copilot-mode is the toggle. It holds C-c i, and it asks by itself: close a
;;; [note] and stop typing, and the paragraph's rewrites come as ghost text.

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

;; SPAN without its closing newlines, or #f when nothing is left
(define (ghost-rewrite--trim buf span)
  (let ((text (buffer-text buf)))
    (and span
         (let loop ((end (min (cadr span) (string-byte-length text))))
           (cond ((<= end (car span)) #f)
                 ((equal? (substring-bytes text (- end 1) end) "\n") (loop (- end 1)))
                 (else (list (car span) end)))))))

;; the paragraph that holds the byte PT
(define (ghost-rewrite--paragraph buf pt)
  (ghost-rewrite--trim buf
    (find (lambda (p) (and (<= (car p) pt) (<= pt (cadr p))))
          (content-scale-paragraphs buf))))

;; the region, else the paragraph at point
(define (ghost-rewrite--span buf)
  (if (mark)
      (ghost-rewrite--trim buf (list (region-beginning) (region-end)))
      (ghost-rewrite--paragraph buf (buffer-point buf))))

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

;; SPAN given is copilot-mode's paragraph: the mark is the user's and stays
(define (ghost-rewrite--start! buf &optional given)
  (let ((span (or given (ghost-rewrite--span buf))))
    (if (not span)
        (message "Nothing to rewrite here: select a passage")
        (let ((start (car span)) (end (cadr span)))
          (unless given (set-mark! #f))
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

(catalog-meta! 'command "ghost-rewrite" 'domain 'writing 'effects '(write external spend))

(defcustom 'copilot-delay-ms 600
  "Milliseconds of no typing after you close a [note] before copilot-mode asks for rewrites."
  'group 'writing 'type 'integer)

;; the byte of the [ that opens a note the ] at END closes, or #f. A
;; [[link]] and a paragraph break are not a note.
(define (copilot--note-open text end)
  (let* ((before (substring-bytes text 0 end))
         (open (string-rindex before "[")))
    (and open
         (> end (+ open 1))
         (let ((note (substring-bytes text open end)))
           (and (not (string-index note "]")) (not (string-index note "\n\n"))))
         (not (and (> open 0) (equal? (substring-bytes text (- open 1) open) "[")))
         open)))

;; the ] at POS still closes a note, and no ( after it makes it a link
(define (copilot--ask-maybe! buf pos)
  (when (and (buffer-exists? buf) (minor-mode-on? buf "copilot-mode")
             (not (ghost-rewrite--state buf)))
    (let* ((text (buffer-text buf))
           (n (string-byte-length text))
           (at (lambda (i) (if (< i n) (substring-bytes text i (+ i 1)) ""))))
      (when (and (equal? (at pos) "]")
                 (not (equal? (at (+ pos 1)) "("))
                 (copilot--note-open text pos))
        (let ((span (ghost-rewrite--paragraph buf pos)))
          (when span (ghost-rewrite--start! buf span)))))))

;; every change starts the wait again; only a typed ] arms it
(define (copilot--setup! buf)
  (buffer-set-local! buf 'copilot-watch
    (on-change! buf
      (lambda (pos inserted deleted source)
        (debounce! (string-append "copilot:" buf) copilot-delay-ms
          (lambda (at) (when at (copilot--ask-maybe! buf at)))
          (and (equal? inserted "]") pos))))))

(define (copilot--teardown! buf)
  (let ((w (buffer-local buf 'copilot-watch)))
    (when w
      (remove-on-change! w)
      (buffer-set-local! buf 'copilot-watch #f)))
  (when (ghost-rewrite--state buf) (ghost-rewrite--dismiss! buf)))

(register-minor-mode! "copilot-mode" copilot--setup! copilot--teardown!)
(minor-mode-keys! "copilot-mode" '(("C-c i" "ghost-rewrite")))
(mode-doc! "copilot-mode"
  "Rewrites come as ghost text, the way Copilot completes. Write what you want in [square brackets] and stop typing: the paragraph lights and its rewrites come. `C-c i` asks for the region or the paragraph at point, and again for more. `TAB` takes the one shown, `M-n` and `M-p` walk them, `C-g` lets them go.")
(define-command "copilot-mode" "Toggle copilot-mode: rewrites come as ghost text when you close a [note]"
  (lambda ()
    (message (if (toggle-minor-mode! "copilot-mode")
                 "copilot-mode on: close a [note] and pause, or C-c i"
                 "copilot-mode off"))))
(catalog-meta! 'command "copilot-mode" 'domain 'writing 'effects '(write))

(effects! '(pure))
(public! 'ghost-rewrite-diff "(ghost-rewrite-diff OLD NEW) — (P OLD-END NEW-END) in characters: OLD[P..OLD-END] gives way to NEW[P..NEW-END], cut on whitespace")
(public! 'ghost-rewrite-parse "(ghost-rewrite-parse REPLY) — the rewrites in a model reply, split on =====")
