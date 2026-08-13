;;; evil.scm — Vim emulation. All policy, two primitives of mechanism.
;;;
;;; M-x evil-mode toggles Vim keys in every eligible buffer (files and
;;; *scratch*; special surfaces — chat, dired, mail, process buffers —
;;; keep their own keys). M-x evil-local-mode toggles one buffer. To make
;;; it permanent, put (evil-mode-on!) in ~/.aimax/init.scm.
;;;
;;; What works: normal/insert/visual/visual-line states; motions h j k l
;;; w b e 0 ^ $ { } f t F T ; , gg G RET DEL SPC with counts; operators
;;; d c y (+ dd cc yy, D C Y S s, cw=ce) over motions and iw/aw; x X r ~
;;; J p P u; v V with o, d/x y c; / ? n N incremental search; ex commands
;;; :w :q :wq :e FILE :N and any M-x name. Not yet: repeat (.), macros,
;;; registers beyond the unnamed one, marks, %.
;;;
;;; How it hangs together: every printable key is buffer-locally bound to
;;; an evil--key-* dispatcher command, so lookup wins before the core's
;;; self-insert fast path. One state machine interprets the key by state
;;; ('evil-state buffer-local — persists and restores with the desktop).
;;; The dispatchers are undo-exempt: the core never auto-breaks the undo
;;; chain for them, and evil places vim's undo boundaries itself —
;;; break-undo-chain! before each normal-mode edit and at insert entry —
;;; so u u u walks history instead of toggling, and an insert run groups.

;;; --- state -------------------------------------------------------------------

(define *evil-enabled* #f)          ; global switch (find-file hook consults it)
(define *evil-count* #f)            ; count before operator, #f = none
(define *evil-count2* #f)           ; count after operator
(define *evil-operator* #f)         ; "d" | "c" | "y" | #f
(define *evil-pending* #f)          ; (find KIND) | (g) | (tobj AROUND?) | (replace)
(define *evil-last-find* #f)        ; (KIND CH) for ; and ,
(define *evil-reg* "")              ; the unnamed register
(define *evil-reg-linewise* #f)
(define *evil-search* "")
(define *evil-search-dir* 1)
(define *evil-search-origin* 0)
(define *evil-visual-anchor* #f)

(define (evil-state) (or (buffer-local (current-buffer) 'evil-state) "normal"))

(define (evil-set-state! st)
  (buffer-set-local! (current-buffer) 'evil-state st)
  (evil--decorate! (current-buffer)))

(define (evil--decorate! buf)
  (let ((st (or (buffer-local buf 'evil-state) "normal")))
    (buffer-set-local! buf 'modeline-info
      (cond ((equal? st "insert") "INSERT")
            ((equal? st "visual") "VISUAL")
            ((equal? st "visual-line") "V-LINE")
            (else "NORMAL")))
    ;; the cursor names the state: warm block in normal, theme color in insert
    (when (boundp (quote face-remap-in!))
      (face-remap-in! buf 'cursor
        (if (equal? st "insert") '() (list 'bg "#b3542c"))))))

(define (evil--reset!)
  (set! *evil-count* #f)
  (set! *evil-count2* #f)
  (set! *evil-operator* #f)
  (set! *evil-pending* #f))

(define (evil--count-given?) (if (or *evil-count* *evil-count2*) #t #f))
(define (evil--eff-count) (* (or *evil-count* 1) (or *evil-count2* 1)))

(define (evil--digit! d)
  (if *evil-operator*
      (set! *evil-count2* (+ (* (or *evil-count2* 0) 10) d))
      (set! *evil-count* (+ (* (or *evil-count* 0) 10) d))))

;;; --- position scanning --------------------------------------------------------
;;; Positions are byte offsets; chars can be multibyte, so all stepping
;;; goes through the char-aware core motions. These clobber point while
;;; computing — callers re-place point from the returned values.

(define (evil--next-pos p) (goto-char! p) (forward-char!))
(define (evil--prev-pos p) (goto-char! p) (backward-char!))

(define (evil--char-after p)
  (goto-char! p)
  (let ((e (forward-char!)))
    (goto-char! p)
    (if (> e p) (buffer-substring p e) #f)))

(define evil--word-chars
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

(define (evil--char-class c)
  (cond ((not c) 'eof)
        ((member c '(" " "\t" "\n")) 'space)
        ((string-contains? evil--word-chars c) 'word)
        (else 'punct)))

(define (evil--line-bounds p)   ; (bol eol), eol = the newline's position (or eob)
  (goto-char! p)
  (let ((b (beginning-of-line!)))
    (goto-char! p)
    (list b (end-of-line!))))

(define (evil--line-end-incl p) ; just past the line's newline (eob on last line)
  (let ((eol (cadr (evil--line-bounds p))))
    (evil--next-pos eol)))

(define (evil--first-non-blank)
  (let* ((lb (evil--line-bounds (point))) (bol (car lb)) (eol (cadr lb)))
    (let loop ((q bol))
      (if (and (< q eol) (member (evil--char-after q) '(" " "\t")))
          (loop (evil--next-pos q))
          (goto-char! q)))))

(define (evil--skip-class p cls)
  (let loop ((q p))
    (if (equal? (evil--char-class (evil--char-after q)) cls)
        (let ((n (evil--next-pos q)))
          (if (> n q) (loop n) q))
        q)))

(define (evil--skip-class-back p cls)  ; start of the CLS run ending at p
  (let loop ((q p))
    (let ((pr (evil--prev-pos q)))
      (if (and (< pr q) (equal? (evil--char-class (evil--char-after pr)) cls))
          (loop pr)
          q))))

;;; --- word motions (vim semantics) ---------------------------------------------

(define (evil--motion-w p)
  (let* ((c (evil--char-class (evil--char-after p)))
         (q (if (member c '(word punct)) (evil--skip-class p c) p)))
    (evil--skip-class q 'space)))

(define (evil--motion-e p)
  (let* ((n (evil--next-pos p))
         (q (evil--skip-class n 'space))
         (c (evil--char-class (evil--char-after q))))
    (if (member c '(word punct))
        (evil--prev-pos (evil--skip-class q c))
        q)))

(define (evil--motion-b p)
  (let* ((q0 (evil--prev-pos p))
         (q (let loop ((q q0))
              (if (and (> q 0)
                       (equal? (evil--char-class (evil--char-after q)) 'space))
                  (loop (evil--prev-pos q))
                  q)))
         (c (evil--char-class (evil--char-after q))))
    (if (member c '(word punct)) (evil--skip-class-back q c) q)))

;;; --- f/t and line motions -------------------------------------------------------

(define (evil--find-target kind ch count)
  (let* ((p (point)) (lb (evil--line-bounds p)) (bol (car lb)) (eol (cadr lb)))
    (if (member kind '("f" "t"))
        (let loop ((q (evil--next-pos p)) (n count))
          (cond ((>= q eol) #f)
                ((equal? (evil--char-after q) ch)
                 (if (= n 1)
                     (if (equal? kind "t") (evil--prev-pos q) q)
                     (loop (evil--next-pos q) (- n 1))))
                (else (let ((nx (evil--next-pos q)))
                        (if (> nx q) (loop nx n) #f)))))
        (let loop ((q (evil--prev-pos p)) (n count))
          (cond ((or (< q bol) (>= q p)) #f)
                ((equal? (evil--char-after q) ch)
                 (if (= n 1)
                     (if (equal? kind "T") (evil--next-pos q) q)
                     (if (= q bol) #f (loop (evil--prev-pos q) (- n 1)))))
                ((= q bol) #f)
                (else (loop (evil--prev-pos q) n)))))))

(define (evil--goto-line n)
  (goto-char! 0)
  (let loop ((i 1))
    (if (< i n) (begin (next-line!) (loop (+ i 1)))))
  (evil--first-non-blank))

;;; --- the motion table -----------------------------------------------------------
;;; -> (target type) or #f; type 'exclusive | 'inclusive | 'linewise.
;;; Moves point freely while computing; callers restore from the result.

(define (evil--motion-target k count given)
  (let ((p (point)))
    (cond
      ((equal? k "h")
       (let ((bol (car (evil--line-bounds p))))
         (let loop ((q p) (n count))
           (if (or (= n 0) (<= q bol))
               (list (max bol q) 'exclusive)
               (loop (evil--prev-pos q) (- n 1))))))
      ((or (equal? k "l") (equal? k "SPC"))
       (let ((eol (cadr (evil--line-bounds p))))
         (let loop ((q p) (n count))
           (if (or (= n 0) (>= q eol))
               (list (min eol q) 'exclusive)
               (loop (evil--next-pos q) (- n 1))))))
      ((equal? k "DEL")
       (let loop ((q p) (n count))
         (if (= n 0) (list q 'exclusive)
             (loop (evil--prev-pos q) (- n 1)))))
      ((equal? k "j")
       (goto-char! p) (move-lines count next-line!) (list (point) 'linewise))
      ((equal? k "k")
       (goto-char! p) (move-lines count previous-line!) (list (point) 'linewise))
      ((equal? k "RET")
       (goto-char! p) (move-lines count next-line!)
       (evil--first-non-blank) (list (point) 'linewise))
      ((equal? k "w")
       (let loop ((q p) (n count))
         (if (= n 0) (list q 'exclusive) (loop (evil--motion-w q) (- n 1)))))
      ((equal? k "e")
       (let loop ((q p) (n count))
         (if (= n 0) (list q 'inclusive) (loop (evil--motion-e q) (- n 1)))))
      ((equal? k "b")
       (let loop ((q p) (n count))
         (if (= n 0) (list q 'exclusive) (loop (evil--motion-b q) (- n 1)))))
      ((equal? k "0") (list (car (evil--line-bounds p)) 'exclusive))
      ((equal? k "^")
       (goto-char! p) (evil--first-non-blank) (list (point) 'exclusive))
      ((equal? k "$")
       (goto-char! p) (move-lines (- count 1) next-line!)
       (list (end-of-line!) 'exclusive))
      ((equal? k "}")
       (let loop ((q p) (n count))
         (if (= n 0) (list q 'exclusive)
             (let ((m (buffer-search "\n\n"
                        (min (buffer-size (current-buffer)) (+ q 1)))))
               (loop (if m (+ (car m) 1) (buffer-size (current-buffer)))
                     (- n 1))))))
      ((equal? k "{")
       (let loop ((q p) (n count))
         (if (= n 0) (list q 'exclusive)
             (let ((m (buffer-search-backward "\n\n" (max 0 (- q 1)))))
               (loop (if m (+ (car m) 1) 0) (- n 1))))))
      ((equal? k "G")
       (if given
           (evil--goto-line count)
           (begin (end-of-buffer!) (evil--first-non-blank)))
       (list (point) 'linewise))
      (else #f))))

;;; --- register & operators --------------------------------------------------------

(define (evil--yank-range s e linewise)
  (let ((text (if (> e s) (buffer-substring s e) "")))
    (set! *evil-reg*
      (if (and linewise (not (string-suffix? "\n" text)))
          (string-append text "\n")     ; linewise text is always \n-terminated
          text))
    (set! *evil-reg-linewise* linewise)
    (unless (equal? text "") (kill-push! *evil-reg*))))

(define (evil--enter-insert!) (evil-set-state! "insert"))

;; one operator application; START is where point stood when the operator
;; was struck, TARGET/TYPE the resolved motion
(define (evil--do-operator op start target type)
  (if (equal? type 'linewise)
      (let* ((lo (min start target)) (hi (max start target))
             (sb (car (evil--line-bounds lo))))
        (cond
          ((equal? op "y")
           (evil--yank-range sb (evil--line-end-incl hi) #t)
           (goto-char! sb)
           (message "Yanked"))
          ((equal? op "c")
           ;; change keeps the trailing newline: lines collapse to one empty
           (break-undo-chain!)
           (evil--yank-range sb (evil--line-end-incl hi) #t)
           (let ((eb (cadr (evil--line-bounds hi))))
             (when (> eb sb) (delete-between! sb eb)))
           (goto-char! sb)
           (evil--enter-insert!))
          (else
           (break-undo-chain!)
           (let ((eb (evil--line-end-incl hi)))
             (evil--yank-range sb eb #t)
             (when (> eb sb) (delete-between! sb eb)))
           (evil--first-non-blank))))
      (let* ((s (min start target))
             (e0 (max start target))
             (e (if (equal? type 'inclusive) (evil--next-pos e0) e0)))
        (cond
          ((equal? op "y")
           (evil--yank-range s e #f)
           (goto-char! s)
           (message "Yanked"))
          ((equal? op "c")
           (break-undo-chain!)
           (evil--yank-range s e #f)
           (when (> e s) (delete-between! s e))
           (evil--enter-insert!))
          (else
           (break-undo-chain!)
           (evil--yank-range s e #f)
           (when (> e s) (delete-between! s e)))))))

;; dd / yy / cc — the operator doubled: this line, count-1 more below
(define (evil--op-line op)
  (let ((n (evil--eff-count)) (start (point)))
    (evil--reset!)
    (goto-char! start)
    (let ((target (if (> n 1)
                      (begin (move-lines (- n 1) next-line!) (point))
                      start)))
      (goto-char! start)
      (evil--do-operator op start target 'linewise))))

;; a resolved motion lands here: apply the pending operator or just move
(define (evil--finish-motion start target type)
  (let ((op *evil-operator*))
    (evil--reset!)
    (if op
        (begin (goto-char! start) (evil--do-operator op start target type))
        (begin
          (goto-char! target)
          (when (equal? (evil-state) "visual-line") (evil--vline-refresh!))))))

(define (evil--try-motion k)
  (let* ((k2 (if (and (equal? *evil-operator* "c") (equal? k "w")) "e" k))
         (start (point))
         (m (evil--motion-target k2 (evil--eff-count) (evil--count-given?))))
    (if m
        (begin (evil--finish-motion start (car m) (cadr m)) #t)
        (begin (goto-char! start) #f))))

;;; --- text objects (word) ---------------------------------------------------------

(define (evil--textobj-range around)
  (let* ((p (point)) (c (evil--char-class (evil--char-after p))))
    (if (equal? c 'eof)
        #f
        (let ((s (evil--skip-class-back p c))
              (e (evil--skip-class p c)))
          (if around
              (let ((e2 (evil--skip-class e 'space)))
                (if (> e2 e)
                    (list s e2)
                    (list (evil--skip-class-back s 'space) e)))
              (list s e))))))

;;; --- simple edit commands ---------------------------------------------------------

(define (evil--cmd-x count)
  (let* ((p (point)) (eol (cadr (evil--line-bounds p))))
    (if (>= p eol)
        (message "Nothing to delete")
        (let ((e (let loop ((q p) (n count))
                   (if (or (= n 0) (>= q eol)) (min q eol)
                       (loop (evil--next-pos q) (- n 1))))))
          (break-undo-chain!)
          (evil--yank-range p e #f)
          (delete-between! p e)))))

(define (evil--cmd-X count)
  (let* ((p (point)) (bol (car (evil--line-bounds p))))
    (if (<= p bol)
        (message "Nothing to delete")
        (let ((s (let loop ((q p) (n count))
                   (if (or (= n 0) (<= q bol)) (max q bol)
                       (loop (evil--prev-pos q) (- n 1))))))
          (break-undo-chain!)
          (evil--yank-range s p #f)
          (delete-between! s p)))))

(define (evil--cmd-paste after count)
  (if (equal? *evil-reg* "")
      (message "Nothing in register")
      (begin
        (break-undo-chain!)
        (let ((text (string-repeat *evil-reg* count)))
          (if *evil-reg-linewise*
              (let* ((p (point))
                     (at (if after (evil--line-end-incl p)
                             (car (evil--line-bounds p))))
                     (eol (cadr (evil--line-bounds p))))
                (if (and after (= at eol))
                    ;; last line without newline: open one, drop the final \n
                    (begin
                      (goto-char! at)
                      (insert! (string-append "\n"
                        (substring-bytes text 0 (- (string-byte-length text) 1))))
                      (goto-char! (+ at 1)))
                    (begin (goto-char! at) (insert! text) (goto-char! at)))
                (evil--first-non-blank))
              (let* ((p (point)) (eol (cadr (evil--line-bounds p))))
                (goto-char! p)
                (when (and after (< p eol)) (forward-char!))
                (insert! text)
                (backward-char!)))))))

(define (evil--cmd-join count)
  (break-undo-chain!)
  (let loop ((n (max 1 (- count 1))))
    (when (> n 0)
      (let ((eol (cadr (evil--line-bounds (point)))))
        (if (>= eol (buffer-size (current-buffer)))
            (message "Nothing to join")
            (let ((e (let skip ((q (evil--next-pos eol)))
                       (if (member (evil--char-after q) '(" " "\t"))
                           (skip (evil--next-pos q))
                           q))))
              (delete-between! eol e)
              (goto-char! eol)
              (insert! " ")
              (backward-char!)
              (loop (- n 1))))))))

(define (evil--cmd-tilde count)
  (break-undo-chain!)
  (let loop ((n count))
    (let ((c (evil--char-after (point))))
      (when (and (> n 0) c (not (equal? c "\n")))
        (delete-char! 1)
        (insert! (if (equal? c (string-upcase c))
                     (string-downcase c)
                     (string-upcase c)))
        (loop (- n 1))))))

(define (evil--replace-char ch count)
  (let ((c (evil--char-after (point))))
    (when (and c (not (equal? c "\n")))
      (break-undo-chain!)
      (let loop ((n count))
        (let ((cc (evil--char-after (point))))
          (when (and (> n 0) cc (not (equal? cc "\n")))
            (delete-char! 1)
            (insert! ch)
            (loop (- n 1)))))
      (backward-char!))))

;;; --- search (/ ? n N) --------------------------------------------------------------

(define (evil--search-jump q d from)
  (let ((m (if (> d 0) (buffer-search q from) (buffer-search-backward q from))))
    (if m
        (goto-char! (car m))
        (let ((m2 (if (> d 0)
                      (buffer-search q 0)
                      (buffer-search-backward q (buffer-size (current-buffer))))))
          (if m2
              (begin (goto-char! (car m2)) (message "Search wrapped"))
              (message (string-append "Pattern not found: " q)))))))

(define (evil-search dir)
  (set! *evil-search-origin* (point))
  (minibuffer-read* (if (> dir 0) "/" "?") '()
    (list (list 'change
            (lambda (q)
              (with-window-buffer
                (lambda ()
                  (if (equal? q "")
                      (goto-char! *evil-search-origin*)
                      (let ((m (if (> dir 0)
                                   (buffer-search q *evil-search-origin*)
                                   (buffer-search-backward q *evil-search-origin*))))
                        (if m (goto-char! (car m)))))))))
          (list 'confirm
            (lambda (q)
              (if (equal? q "")
                  (goto-char! *evil-search-origin*)
                  (begin
                    (set! *evil-search* q)
                    (set! *evil-search-dir* dir)
                    (evil--search-jump q dir *evil-search-origin*)))))
          (list 'cancel
            (lambda () (goto-char! *evil-search-origin*))))))

(define (evil--search-next dir)
  (if (equal? *evil-search* "")
      (message "No previous search")
      (let* ((d (* dir *evil-search-dir*))
             (from (if (> d 0) (evil--next-pos (point)) (point))))
        (goto-char! from)
        (evil--search-jump *evil-search* d from))))

;;; --- ex commands (:) ----------------------------------------------------------------

(define (evil--ex-run cmd)
  (cond
    ((equal? cmd "") #f)
    ((member cmd '("w" "w!")) (run-command "save-buffer"))
    ((member cmd '("q" "q!")) (run-command "delete-window"))
    ((member cmd '("wq" "wq!" "x"))
     (run-command "save-buffer") (run-command "delete-window"))
    ((member cmd '("qa" "qa!" "quitall"))
     (message "The editor outlives :qa — close the browser tab instead"))
    ((string-prefix? "e " cmd)
     (visit (expand-path (string-trim (substring cmd 2 (string-length cmd))))))
    ((number? (string->number cmd)) (evil--goto-line (string->number cmd)))
    ((member cmd (command-names)) (run-command cmd))   ; :any-M-x-command
    (else (message (string-append "Not an ex command: " cmd)))))

(define (evil-ex)
  (minibuffer-read ":" '()
    (lambda (cmd) (evil--ex-run (string-trim cmd)))))

;;; --- visual state --------------------------------------------------------------------

(define (evil--vline-refresh!)
  (let ((a *evil-visual-anchor*) (p (point)))
    (if (>= p a)
        (begin
          (set-mark! (car (evil--line-bounds a)))
          (goto-char! (cadr (evil--line-bounds p))))
        (begin
          (set-mark! (evil--line-end-incl a))
          (goto-char! (car (evil--line-bounds p)))))))

(define (evil--visual-enter! linewise)
  (evil--reset!)
  (set! *evil-visual-anchor* (point))
  (if linewise
      (begin (evil-set-state! "visual-line") (evil--vline-refresh!))
      (begin (evil-set-state! "visual") (set-mark! (point)))))

(define (evil--visual-exit!)
  (set-mark! #f)
  (set! *evil-visual-anchor* #f)
  (evil--reset!)
  (evil-set-state! "normal"))

(define (evil--visual-op op)
  (let* ((a *evil-visual-anchor*) (p (point))
         (lw (equal? (evil-state) "visual-line"))
         (lo (min a p)) (hi (max a p)))
    (evil--visual-exit!)
    (if lw
        (evil--do-operator op lo hi 'linewise)
        (evil--do-operator op lo hi 'inclusive))))

;;; --- the state machine ----------------------------------------------------------------

(define (evil--insert-key k)
  (cond
    ((equal? k "ESC")
     (evil--reset!)
     (let* ((p (point)) (bol (car (evil--line-bounds p))))
       (goto-char! p)
       (when (> p bol) (backward-char!)))
     (evil-set-state! "normal"))
    ((equal? k "RET") (insert! "\n"))
    ((equal? k "DEL") (delete-char! -1))
    ((equal? k "SPC") (insert! " "))
    (else (insert! k))))

(define (evil--key-char k)   ; the literal char a pending state consumes
  (cond ((equal? k "SPC") " ")
        ((member k '("ESC" "RET" "DEL" "TAB")) #f)
        (else k)))

(define (evil--modal-key k)
  (let ((st (evil-state)))
    (cond
      ;; a restored visual state without its anchor falls back to normal
      ((and (member st '("visual" "visual-line")) (not *evil-visual-anchor*))
       (evil-set-state! "normal")
       (evil--modal-key k))

      ((equal? k "ESC")
       (if (member st '("visual" "visual-line"))
           (evil--visual-exit!)
           (begin (evil--reset!) (set-mark! #f))))

      ;; pending: r, f/F/t/T, g, text objects
      ((and *evil-pending* (equal? (car *evil-pending*) 'replace))
       (let ((ch (evil--key-char k)) (n (evil--eff-count)))
         (evil--reset!)
         (when ch (evil--replace-char ch n))))
      ((and *evil-pending* (equal? (car *evil-pending*) 'find))
       (let ((kind (cadr *evil-pending*)) (ch (evil--key-char k)))
         (if (not ch)
             (evil--reset!)
             (begin
               (set! *evil-last-find* (list kind ch))
               (evil--pending-find kind ch)))))
      ((and *evil-pending* (equal? (car *evil-pending*) 'g))
       (if (equal? k "g")
           (let ((start (point)) (n (evil--eff-count)) (given (evil--count-given?)))
             (set! *evil-pending* #f)
             (goto-char! start)
             (if given (evil--goto-line n) (evil--goto-line 1))
             (evil--finish-motion start (point) 'linewise))
           (evil--reset!)))
      ((and *evil-pending* (equal? (car *evil-pending*) 'tobj))
       (let ((around (cadr *evil-pending*))
             (op *evil-operator*)
             (start (point)))
         (if (equal? k "w")
             (let ((r (evil--textobj-range around)))
               (evil--reset!)
               (goto-char! start)
               (if r
                   (evil--do-operator op (car r) (cadr r) 'exclusive)))
             (evil--reset!))))

      ;; counts
      ((member k '("1" "2" "3" "4" "5" "6" "7" "8" "9"))
       (evil--digit! (string->number k)))
      ((and (equal? k "0")
            (if *evil-operator* *evil-count2* *evil-count*))
       (evil--digit! 0))

      ;; operators
      ((member k '("d" "c" "y"))
       (cond
         ((member st '("visual" "visual-line")) (evil--visual-op k))
         ((equal? *evil-operator* k) (evil--op-line k))
         (else (set! *evil-operator* k))))
      ((and (equal? k "x") (member st '("visual" "visual-line")))
       (evil--visual-op "d"))

      ;; motions (0 arrives here only as bol)
      ((evil--try-motion k) #t)

      ;; pending initiators
      ((member k '("f" "F" "t" "T")) (set! *evil-pending* (list 'find k)))
      ((equal? k "g") (set! *evil-pending* (list 'g)))
      ((and *evil-operator* (member k '("i" "a")))
       (set! *evil-pending* (list 'tobj (equal? k "a"))))
      ((equal? k ";")
       (if *evil-last-find*
           (evil--pending-find (car *evil-last-find*) (cadr *evil-last-find*))
           (evil--reset!)))
      ((equal? k ",")
       (if *evil-last-find*
           (evil--pending-find (evil--find-invert (car *evil-last-find*))
                               (cadr *evil-last-find*))
           (evil--reset!)))

      ;; visual entry / tweaks
      ((equal? k "v")
       (if (member st '("visual" "visual-line"))
           (evil--visual-exit!)
           (evil--visual-enter! #f)))
      ((equal? k "V")
       (if (equal? st "visual-line")
           (evil--visual-exit!)
           (evil--visual-enter! #t)))
      ((and (equal? k "o") (member st '("visual" "visual-line")))
       (let ((a *evil-visual-anchor*))
         (set! *evil-visual-anchor* (point))
         (goto-char! a)
         (if (equal? st "visual-line")
             (evil--vline-refresh!)
             (set-mark! *evil-visual-anchor*))))

      ;; insert entries
      ((equal? k "i")
       (evil--reset!) (break-undo-chain!) (evil--enter-insert!))
      ((equal? k "a")
       (evil--reset!) (break-undo-chain!)
       (let* ((p (point)) (eol (cadr (evil--line-bounds p))))
         (goto-char! p)
         (when (< p eol) (forward-char!)))
       (evil--enter-insert!))
      ((equal? k "A")
       (evil--reset!) (break-undo-chain!) (end-of-line!) (evil--enter-insert!))
      ((equal? k "I")
       (evil--reset!) (break-undo-chain!) (evil--first-non-blank)
       (evil--enter-insert!))
      ((equal? k "o")
       (evil--reset!) (break-undo-chain!) (end-of-line!) (insert! "\n")
       (evil--enter-insert!))
      ((equal? k "O")
       (evil--reset!) (break-undo-chain!) (beginning-of-line!) (insert! "\n")
       (backward-char!) (evil--enter-insert!))

      ;; edits
      ((equal? k "x")
       (let ((n (evil--eff-count))) (evil--reset!) (evil--cmd-x n)))
      ((equal? k "X")
       (let ((n (evil--eff-count))) (evil--reset!) (evil--cmd-X n)))
      ((equal? k "s")
       (let ((n (evil--eff-count))) (evil--reset!)
         (evil--cmd-x n) (evil--enter-insert!)))
      ((equal? k "r") (set! *evil-pending* (list 'replace)))
      ((equal? k "~")
       (let ((n (evil--eff-count))) (evil--reset!) (evil--cmd-tilde n)))
      ((equal? k "J")
       (let ((n (evil--eff-count))) (evil--reset!) (evil--cmd-join n)))
      ((equal? k "p")
       (let ((n (evil--eff-count))) (evil--reset!) (evil--cmd-paste #t n)))
      ((equal? k "P")
       (let ((n (evil--eff-count))) (evil--reset!) (evil--cmd-paste #f n)))
      ((equal? k "D")
       (evil--reset!)
       (let* ((p (point)) (eol (cadr (evil--line-bounds p))))
         (evil--do-operator "d" p eol 'exclusive)))
      ((equal? k "C")
       (evil--reset!)
       (let* ((p (point)) (eol (cadr (evil--line-bounds p))))
         (evil--do-operator "c" p eol 'exclusive)))
      ((equal? k "Y") (set! *evil-operator* "y") (evil--op-line "y"))
      ((equal? k "S") (set! *evil-operator* "c") (evil--op-line "c"))
      ((equal? k "u")
       (let ((n (evil--eff-count)))
         (evil--reset!)
         (let loop ((i 0))
           (if (< i n)
               (if (undo!) (loop (+ i 1))
                   (message "No further undo information"))))))

      ;; search & ex
      ((equal? k "/") (evil--reset!) (evil-search 1))
      ((equal? k "?") (evil--reset!) (evil-search -1))
      ((equal? k "n") (evil--reset!) (evil--search-next 1))
      ((equal? k "N") (evil--reset!) (evil--search-next -1))
      ((equal? k ":") (evil--reset!) (evil-ex))

      (else (evil--reset!)))))

(define (evil--find-invert kind)
  (cond ((equal? kind "f") "F") ((equal? kind "F") "f")
        ((equal? kind "t") "T") (else "t")))

;; resolve an f/t motion (fresh or repeated via ;/,) against the operator
(define (evil--pending-find kind ch)
  (let ((start (point)) (n (evil--eff-count)))
    (set! *evil-pending* #f)
    (goto-char! start)
    (let ((target (evil--find-target kind ch n)))
      (if target
          (evil--finish-motion start target
            (if (member kind '("f" "t")) 'inclusive 'exclusive))
          (begin
            (evil--reset!)
            (goto-char! start)
            (message (string-append kind ch ": not found on this line")))))))

;;; --- dispatch & wiring -------------------------------------------------------------

;; keys stay bound when the minor mode is off (there is no unbind
;; primitive) — the dispatcher then reproduces the default behavior
(define (evil--passthrough k)
  (cond ((equal? k "RET") (run-command "newline-or-send"))
        ((equal? k "DEL") (delete-char! -1))
        ((equal? k "SPC") (insert! " "))
        ((equal? k "ESC") #f)
        (else (insert! k))))

(define (evil-dispatch! k)
  (if (not (minor-mode-on? (current-buffer) "evil-local-mode"))
      (evil--passthrough k)
      (if (equal? (evil-state) "insert")
          (evil--insert-key k)
          (evil--modal-key k))))

(define evil--printables
  (string-append
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"))

(define *evil-keys*
  (let loop ((i 0) (acc (list "ESC" "RET" "DEL" "SPC")))
    (if (>= i (string-length evil--printables))
        (reverse acc)
        (loop (+ i 1)
              (cons (substring evil--printables i (+ i 1)) acc)))))

(for-each
  (lambda (k)
    (let ((name (string-append "evil--key-" k)))
      (define-command name (lambda () (evil-dispatch! k)))
      (undo-exempt! name)))
  *evil-keys*)

(define (evil--setup! buf)
  (for-each
    (lambda (k) (local-set-key* buf k (string-append "evil--key-" k)))
    *evil-keys*)
  (unless (buffer-local buf 'evil-state)
    (buffer-set-local! buf 'evil-state "normal"))
  (evil--decorate! buf))

(define (evil--teardown! buf)
  (buffer-set-local! buf 'evil-state #f)
  (buffer-set-local! buf 'modeline-info #f)
  (when (boundp (quote face-remap-in!))
    (face-remap-in! buf 'cursor '())))

(register-minor-mode! "evil-local-mode" evil--setup! evil--teardown!)

;; vim keys make sense in text you edit — not in special surfaces that
;; carry their own single-key commands
(define (evil--eligible? buf)
  (and (not (string-prefix? " " buf))
       (not (process-running? buf))
       (or (buffer-path buf) (equal? buf "*scratch*"))
       (not (member (or (buffer-local buf 'mode-name) "")
                    '("chat-mode" "dired-mode" "notmuch-mode")))))

(define (evil-mode-on!)
  (set! *evil-enabled* #t)
  (for-each
    (lambda (b)
      (when (and (evil--eligible? b) (not (minor-mode-on? b "evil-local-mode")))
        (enable-minor-mode! b "evil-local-mode")))
    (buffer-list)))

(define (evil-mode-off!)
  (set! *evil-enabled* #f)
  (for-each
    (lambda (b)
      (when (minor-mode-on? b "evil-local-mode")
        (disable-minor-mode! b "evil-local-mode")))
    (buffer-list)))

(add-hook! 'find-file-hook
  (lambda ()
    (let ((buf (current-buffer)))
      (when (and *evil-enabled*
                 (evil--eligible? buf)
                 (not (minor-mode-on? buf "evil-local-mode")))
        (enable-minor-mode! buf "evil-local-mode")))))

(define-command "evil-mode" "Toggle Vim emulation everywhere (files + *scratch*)"
  (lambda ()
    (if *evil-enabled*
        (begin (evil-mode-off!) (message "Evil mode disabled"))
        (begin
          (evil-mode-on!)
          (message "Evil mode — ESC normal · i insert · :q closes the window")))))

(define-command "evil-local-mode" "Toggle Vim emulation in this buffer"
  (lambda ()
    (if (toggle-minor-mode! "evil-local-mode")
        (message "Evil here — ESC for normal mode")
        (message "Evil off in this buffer"))))

(category! 'evil)
(public! 'evil-mode-on! "Enable Vim emulation everywhere; put (evil-mode-on!) in init.scm to make it stick")
(public! 'evil-mode-off! "Disable Vim emulation everywhere")
