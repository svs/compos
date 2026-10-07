;;; repl.scm --- the editor's own Scheme, live, with a history you can edit.
;;;
;;; M-: runs one form and forgets it. This is the other half: a buffer that
;;; keeps every form, so the last one is one keystroke away and editable
;;; before it runs again. M-x repl opens one, and opens another every time you
;;; ask; they are separate sessions over one shared past. The transcript is the history. M-p walks it into
;;; the prompt, <up> walks only the forms that start with what you have
;;; typed, C-c M-r searches them all, and RET on any earlier form in the
;;; buffer brings it back down to the prompt without running it.
;;;
;;; The buffer is scheme-repl-mode, derived from scheme-mode, so completion,
;;; paredit, M-. and the colours are the ones a .scm file gets. Values and
;;; errors land as comments, so the transcript stays Scheme: a region of it
;;; yanks into a file and runs.
;;;
;;; The past is the editor's one keyed history ring, under 'scheme-eval, the
;;; ring every prompt reads, so it survives a restart and M-: shares it.

;; the REPL derives its mode from scheme-mode
(require 'scheme-ide)

(domain! 'code)
(effects! '(pure))

(define *scheme-repl-buffer* "*scheme*")
(define *scheme-repl-prompt* "scm> ")
(define *scheme-repl-history* 'scheme-eval)
(define *scheme-repl-value* ";;=> ")
(define *scheme-repl-error* ";;!! ")
(define *scheme-repl-banner*
  (string-append
    ";;; The editor's Scheme, live. RET runs the form at the prompt; an\n"
    ";;; unfinished one gets a newline instead. <up> and <down> walk the forms\n"
    ";;; that open with what you typed, M-p and M-n walk every one of them,\n"
    ";;; C-c M-r searches them, and RET on a form above brings it back here\n"
    ";;; to edit. *1 *2 *3 are the last three values, *e the last error.\n"
    "\n"))

;; The last three values and the last error, for the next form to name. A
;; value worth a second look is already in a variable; nothing needs saying
;; twice.
(defvar '*1 #f "The value of the last form the Scheme REPL evaluated.")
(defvar '*2 #f "The value the Scheme REPL had in *1 before that.")
(defvar '*3 #f "The value the Scheme REPL had in *2 before that.")
(defvar '*e #f "The message of the last error in the Scheme REPL.")

;;; --- how far from closed ---------------------------------------------------
;;; A REPL needs one answer the reader will not give: is this form finished,
;;; or is the user still typing it? scheme-read says #f both to (+ 1 and to a
;;; stray ), and RET owes the first a newline and the second an error. So
;;; count the delimiters once, respecting everything that hides one: a
;;; string, an escape inside it, a line comment, a nested block comment, and
;;; a character literal.

(define (repl--byte text i) (substring-bytes text i (+ i 1)))

(define (repl--scan text)
  ;; (DEPTH IN-STRING? BLOCK-COMMENT-DEPTH) at the end of TEXT
  (let ((n (string-byte-length text)))
    (let loop ((i 0) (depth 0) (str #f) (block 0) (line #f))
      (if (>= i n)
          (list depth str block)
          (let ((c (repl--byte text i))
                (d (if (< (+ i 1) n) (repl--byte text (+ i 1)) "")))
            (cond
              (line (loop (+ i 1) depth str block (not (equal? c "\n"))))
              (str (cond ((equal? c "\\") (loop (+ i 2) depth #t block #f))
                         ((equal? c "\"") (loop (+ i 1) depth #f block #f))
                         (else (loop (+ i 1) depth #t block #f))))
              ((> block 0)
               (cond ((and (equal? c "|") (equal? d "#"))
                      (loop (+ i 2) depth #f (- block 1) #f))
                     ((and (equal? c "#") (equal? d "|"))
                      (loop (+ i 2) depth #f (+ block 1) #f))
                     (else (loop (+ i 1) depth #f block #f))))
              ((and (equal? c "#") (equal? d "|")) (loop (+ i 2) depth #f 1 #f))
              ;; a character literal: the paren in #\( opens nothing
              ((and (equal? c "#") (equal? d "\\")) (loop (+ i 3) depth #f block #f))
              ((equal? c "\"") (loop (+ i 1) depth #t block #f))
              ((equal? c ";") (loop (+ i 1) depth #f block #t))
              ((or (equal? c "(") (equal? c "[")) (loop (+ i 1) (+ depth 1) #f block #f))
              ((or (equal? c ")") (equal? c "]")) (loop (+ i 1) (- depth 1) #f block #f))
              (else (loop (+ i 1) depth #f block #f))))))))

;; #t when TEXT is one or more whole forms: RET may run it
(define (repl--complete? text)
  (let ((st (repl--scan text)))
    (and (<= (car st) 0) (not (cadr st)) (= (caddr st) 0))))

;; how deep the unfinished form is, for the indent of its next line
(define (repl--depth text)
  (let ((st (repl--scan text)))
    (if (cadr st) 0 (max 0 (car st)))))

(define (repl--spaces n)
  (let loop ((i 0) (acc ""))
    (if (>= i n) acc (loop (+ i 1) (string-append acc " ")))))

;; a form as one line, for a prompt candidate or an echo
(define (repl--one-line text)
  (string-trim (re-replace-all "[ \t\n]+" text " ")))

;;; --- the input ---------------------------------------------------------------
;;; Input is everything past the marker the last prompt left behind. A marker,
;;; not a number: the user and paredit edit around it, and it still says where
;;; the form starts.

(effects! '(write))

(define (repl--start buf) (buffer-local buf 'repl-input-start))

(define (repl--text buf from to) (substring-bytes (buffer-text buf) from to))

(define (repl-input buf)
  (let ((start (repl--start buf)))
    (if (and start (<= start (buffer-size buf)))
        (repl--text buf start (buffer-size buf))
        "")))

(define (repl-set-input! buf text)
  (let ((start (repl--start buf)))
    (when start
      (buffer-replace-range! buf start (- (buffer-size buf) start) text)
      (buffer-goto! buf (buffer-size buf))
      (buffer-windows-follow-point! buf))))

(define (repl--prompt-line? line) (string-prefix? *scheme-repl-prompt* line))
(define (repl--output-line? line) (string-prefix? ";;" line))

;; a fresh prompt at the end, and the marker behind it
(define (repl--prompt! buf)
  (let ((size (buffer-size buf)))
    (unless (or (= size 0) (equal? (repl--text buf (- size 1) size) "\n"))
      (buffer-insert! buf size "\n")))
  (buffer-insert! buf (buffer-size buf) *scheme-repl-prompt*)
  (buffer-set-local! buf 'repl-input-start (buffer-size buf))
  (buffer-goto! buf (buffer-size buf))
  (buffer-windows-follow-point! buf))

;; TEXT behind PREFIX, one line at a time, so a value of many lines is a
;; comment of many lines and the transcript stays Scheme
(define (repl--emit! buf prefix text suffix)
  (let ((rows (map (lambda (l) (string-append prefix l))
                   (string-split (string-trim text) "\n"))))
    (buffer-insert! buf (buffer-size buf)
      (string-append (string-join rows "\n") suffix "\n"))))

;; a form fast enough to feel instant says nothing about its time
(define (repl--ms-label ms)
  (cond ((< ms 200) "")
        ((< ms 1000) (string-append "   ;; " (number->string ms) "ms"))
        (else (string-append "   ;; " (number->string (quotient ms 1000))
                             "." (number->string (quotient (remainder ms 1000) 100))
                             "s"))))

(define (repl--remember! value)
  (set-symbol-value! '*3 *2)
  (set-symbol-value! '*2 *1)
  (set-symbol-value! '*1 value))

;;; --- the transcript is the history -------------------------------------------
;;; RET on an earlier form does not run it. It brings it down to the prompt,
;;; where it is ordinary text: edit it, and the next RET runs what you now
;;; have. A form you ran once is never retyped, and never re-run by accident.

;; the source of the entry POS stands in, or #f. An output line answers with
;; the form that made it, so RET on a result brings that form back too.
(define (repl--entry-at buf pos)
  (let loop ((lines (string-split (buffer-text buf) "\n")) (off 0) (src #f))
    (if (null? lines)
        #f
        (let* ((line (car lines))
               (end (+ off (string-byte-length line)))
               (src2 (cond ((repl--prompt-line? line)
                            (list (substring-bytes line
                                    (string-byte-length *scheme-repl-prompt*)
                                    (string-byte-length line))))
                           ((repl--output-line? line) src)
                           ((equal? (string-trim line) "") src)
                           (src (append src (list line)))
                           (else src))))
          (if (and src2 (>= pos off) (<= pos end))
              (string-join src2 "\n")
              (loop (cdr lines) (+ end 1) src2))))))

;; where input starts in a buffer whose marker is gone: after a restart the
;; text came back and the buffer-local did not
(define (repl--tail-start text)
  (let loop ((lines (string-split text "\n")) (off 0) (start #f))
    (if (null? lines)
        start
        (let* ((line (car lines))
               (end (+ off (string-byte-length line))))
          (loop (cdr lines) (+ end 1)
                (cond ((repl--prompt-line? line)
                       (+ off (string-byte-length *scheme-repl-prompt*)))
                      ((repl--output-line? line) #f)
                      (else start)))))))

(define (repl--sync! buf)
  (when (= (buffer-size buf) 0)
    (buffer-insert! buf 0 *scheme-repl-banner*))
  (let ((start (repl--tail-start (buffer-text buf))))
    (if start
        (buffer-set-local! buf 'repl-input-start start)
        (repl--prompt! buf))))

(define (repl--forget-walk! buf)
  (buffer-set-local! buf 'repl-hist-pos -1)
  (buffer-set-local! buf 'repl-hist-last #f)
  (buffer-set-local! buf 'repl-hist-stash #f)
  (buffer-set-local! buf 'repl-hist-prefix ""))

;; DELTA 1 is one form older. MATCHING? keeps only the forms that open with
;; what stood at the prompt when the walk began, which is how you reach the
;; one form you want out of fifty.
(define (repl--walk! buf delta matching?)
  (let* ((cur (repl-input buf))
         (prev (or (buffer-local buf 'repl-hist-pos) -1))
         (last (buffer-local buf 'repl-hist-last))
         ;; the walk starts over whenever the input is not what the walk put
         ;; there: you typed, so the walk is about what you typed now
         (fresh (or (= prev -1) (not (equal? cur last))))
         (pos (if fresh -1 prev)))
    (when fresh
      (buffer-set-local! buf 'repl-hist-stash cur)
      (buffer-set-local! buf 'repl-hist-prefix (if matching? (string-trim cur) "")))
    (let* ((prefix (or (buffer-local buf 'repl-hist-prefix) ""))
           (items (filter (lambda (s) (string-prefix? prefix s))
                          (history-items *scheme-repl-history*)))
           (next (+ pos delta)))
      (cond ((null? items) (message "No form in the history opens with that"))
            ((< next -1) (message "Back at what you typed"))
            ((>= next (length items)) (message "End of history"))
            (else
              (let ((text (if (= next -1)
                              (or (buffer-local buf 'repl-hist-stash) "")
                              (nth next items))))
                (repl-set-input! buf text)
                (buffer-set-local! buf 'repl-hist-pos next)
                (buffer-set-local! buf 'repl-hist-last text)
                (when (>= next 0)
                  (message (string-append (number->string (+ next 1)) "/"
                                          (number->string (length items)))))))))))

(effects! '(write execute))

;; SRC is whole: run it, and put what it answered in the transcript and in *1
(define (repl-eval! buf src)
  (history-push! *scheme-repl-history* src)
  (repl--forget-walk! buf)
  (buffer-insert! buf (buffer-size buf) "\n")
  (let* ((t0 (monotonic-ms))
         (r (eval-string-safe src))
         (ms (- (monotonic-ms) t0)))
    (if (equal? (car r) 'ok)
        ;; a define answers with nothing, and nothing is what that deserves:
        ;; silence in the transcript is the form that worked
        (let ((printed (value->string (cadr r))))
          (unless (equal? printed "")
            (repl--remember! (cadr r))
            (repl--emit! buf *scheme-repl-value* printed (repl--ms-label ms))))
        (begin (set-symbol-value! '*e (cadr r))
               (repl--emit! buf *scheme-repl-error* (cadr r) ""))))
  ;; one blank line between entries: the transcript is read as much as it is
  ;; typed into
  (buffer-insert! buf (buffer-size buf) "\n")
  (repl--prompt! buf))

;; The arrows are history where they have nowhere else to go. On the first
;; line of the form <up> walks back, and anywhere else it moves point: a form
;; of many lines is still a form you move around in. This is why the walk is
;; the matching one — <up> after two typed characters means the last form that
;; opens with them.
(define (repl--arrow! buf back? fallback)
  (let ((start (repl--start buf))
        (pos (buffer-point buf)))
    (cond ((or (not start) (< pos start)) (fallback))
          ((if back?
               (string-index (repl--text buf start pos) "\n")
               (string-index (repl--text buf pos (buffer-size buf)) "\n"))
           (fallback))
          (else (repl--walk! buf (if back? 1 -1) #t)))))

(define (repl--newline! buf)
  (let ((start (repl--start buf))
        (pos (buffer-point buf)))
    (if (and start (>= pos start))
        (insert! (string-append "\n"
                   (repl--spaces (* 2 (repl--depth (repl--text buf start pos))))))
        (insert! "\n"))))

;;; --- the commands ------------------------------------------------------------

(define-command "scheme-repl-newline"
  "Break the line and indent, without running the form"
  (lambda () (repl--newline! (current-buffer))))

(define-command "scheme-repl-return"
  "Run the form at the prompt, or bring the form at point down to the prompt"
  (lambda ()
    (let* ((buf (current-buffer))
           (start (repl--start buf))
           (pos (buffer-point buf)))
      (cond
        ((not start) (insert! "\n"))
        ;; above the prompt: the transcript is a library of forms, not a
        ;; button. Copy, never run.
        ((< pos start)
         (let ((src (repl--entry-at buf pos)))
           (if (and src (not (equal? (string-trim src) "")))
               (begin (repl-set-input! buf src)
                      (repl--forget-walk! buf)
                      (message "Edit it, then RET runs it"))
               (insert! "\n"))))
        (else
          (let ((src (string-trim (repl-input buf))))
            (cond ((equal? src "") (repl--prompt! buf))
                  ((repl--complete? src) (repl-eval! buf src))
                  (else (repl--newline! buf)))))))))

(define-command "scheme-repl-previous-input"
  "Put the previous form at the prompt"
  (lambda () (repl--walk! (current-buffer) 1 #f)))

(define-command "scheme-repl-next-input"
  "Put the next form at the prompt"
  (lambda () (repl--walk! (current-buffer) -1 #f)))

(define-command "scheme-repl-previous-matching-input"
  "Put the previous form that opens with what you typed at the prompt"
  (lambda () (repl--walk! (current-buffer) 1 #t)))

(define-command "scheme-repl-next-matching-input"
  "Put the next form that opens with what you typed at the prompt"
  (lambda () (repl--walk! (current-buffer) -1 #t)))

(define-command "scheme-repl-up"
  "Walk back through the history, or move up inside the form"
  (lambda () (repl--arrow! (current-buffer) #t (lambda () (previous-line!)))))

(define-command "scheme-repl-down"
  "Walk forward through the history, or move down inside the form"
  (lambda () (repl--arrow! (current-buffer) #f (lambda () (next-line!)))))

;;; --- the transcript is a record ----------------------------------------------
;;; What already ran is not text to retype over. Typing anywhere brings you
;;; back to the prompt and types there, the way a terminal does, and a delete
;;; stops at the prompt instead of eating it. Nothing above the prompt is lost
;;; by a key you did not mean.

(define (repl--to-prompt! buf)
  (let ((start (repl--start buf)))
    (when (and start (< (buffer-point buf) start))
      (buffer-goto! buf (buffer-size buf)))))

(define-command "scheme-repl-self-insert"
  "Type at the prompt, wherever point stands"
  (lambda ()
    (repl--to-prompt! (current-buffer))
    (run-command "self-insert-command")))

(define-command "scheme-repl-backward-delete"
  "Delete backward, and never into the prompt or what ran above it"
  (lambda ()
    (let* ((buf (current-buffer))
           (start (repl--start buf)))
      (if (and start (<= (buffer-point buf) start))
          (message "The prompt is not text; what ran above it is a record")
          (run-command (if (minor-mode-on? buf "paredit-mode")
                           "paredit--key-DEL"
                           "delete-backward-char"))))))

;; the byte after every prompt in the transcript, in order
(define (repl--prompt-starts buf)
  (let loop ((lines (string-split (buffer-text buf) "\n")) (off 0) (acc '()))
    (if (null? lines)
        (reverse acc)
        (let* ((line (car lines))
               (end (+ off (string-byte-length line))))
          (loop (cdr lines) (+ end 1)
                (if (repl--prompt-line? line)
                    (cons (+ off (string-byte-length *scheme-repl-prompt*)) acc)
                    acc))))))

;; The arrows mean the history, so this is how you go up into what already ran:
;; entry by entry, the way C-c C-p walks a shell's prompts. RET on one brings it
;; back down.
(define (repl--goto-prompt! buf back?)
  (let* ((pos (buffer-point buf))
         (all (repl--prompt-starts buf))
         (nearer (if back?
                     (reverse (filter (lambda (p) (< p pos)) all))
                     (filter (lambda (p) (> p pos)) all))))
    (if (null? nearer)
        (message (if back? "No entry above this one" "No entry below this one"))
        (buffer-goto! buf (car nearer)))))

(define-command "scheme-repl-previous-prompt"
  "Go up to the previous form in the transcript"
  (lambda () (repl--goto-prompt! (current-buffer) #t)))

(define-command "scheme-repl-next-prompt"
  "Go down to the next form in the transcript"
  (lambda () (repl--goto-prompt! (current-buffer) #f)))

(define-command "scheme-repl-search-history"
  "Search every form you have run and put the one you pick at the prompt"
  (lambda ()
    (let* ((buf (current-buffer))
           (items (history-items *scheme-repl-history*))
           (rows (map (lambda (s)
                        (let ((n (length (string-split s "\n"))))
                          (list (repl--one-line s)
                                (if (> n 1)
                                    (string-append (number->string n) " lines")
                                    ""))))
                      items)))
      (if (null? items)
          (message "No form has run yet")
          (completing-read "Form: " rows
            (lambda (label)
              (let ((hit (filter (lambda (s) (equal? (repl--one-line s) label)) items)))
                (when (pair? hit)
                  (repl-set-input! buf (car hit))
                  (repl--forget-walk! buf))))
            'category 'scheme-form)))))

(define-command "scheme-repl-kill-input"
  "Clear the form at the prompt"
  (lambda ()
    (repl-set-input! (current-buffer) "")
    (repl--forget-walk! (current-buffer))))

(define-command "scheme-repl-clear"
  "Clear the transcript; the form at the prompt stays"
  (lambda ()
    (let* ((buf (current-buffer)) (input (repl-input buf)))
      (buffer-delete-range! buf 0 (buffer-size buf))
      (buffer-insert! buf 0 *scheme-repl-banner*)
      (repl--prompt! buf)
      (repl-set-input! buf input))))

(define-command "scheme-repl-beginning-of-input"
  "Move to the start of the form at the prompt"
  (lambda ()
    (let* ((buf (current-buffer))
           (start (repl--start buf))
           (pos (buffer-point buf)))
      (if (and start (> pos start))
          (buffer-goto! buf start)
          (beginning-of-line!)))))

;;; --- the buffer --------------------------------------------------------------

(mode-doc! "scheme-repl-mode"
  "The editor's Scheme, live. `RET` runs the form at the prompt, and gives an unfinished one a newline and an indent instead; `C-j` always breaks the line. `<up>` and `<down>` walk the forms that open with what you have typed, and move point instead when the form has more than one line; `M-p` and `M-n` always walk, over every form; `M-<up>` and `M-<down>` always walk, over the matching ones, and `C-c M-r` searches them all. `C-c C-p` and `C-c C-n` go up and down the transcript, entry by entry, and `RET` on any form there brings it back down to edit, as does `RET` on the value it left. What ran above the prompt is a record: typing anywhere types at the prompt, and a delete stops at the prompt instead of eating it. `C-c C-u` clears the prompt, `C-c M-o` clears the transcript, `C-a` goes to the start of the form, `C-c C-z` goes back to the buffer you came from, and `M-x repl` opens another REPL beside this one. `*1` `*2` `*3` are the last three values and `*e` is the last error. Values and errors land as comments, so a region of the transcript yanks into a file and runs. The past is the history every prompt keeps, so `M-:` shares it and a restart does not lose it.")

;; scheme-mode is the parent, and that is the whole point: completion, paredit,
;; M-. and the colours are the ones a .scm file gets, with nothing copied.
(define-derived-mode "scheme-repl-mode" "scheme-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-marker-local! buf 'repl-input-start 'stay)
      ;; the text is durable; where the prompt stood is not. repl--sync! reads
      ;; it back from the transcript, so a restored buffer needs no offsets.
      (desktop-skip! buf 'repl-input-start)
      (desktop-skip! buf 'repl-hist-pos)
      (desktop-skip! buf 'repl-hist-last)
      (desktop-skip! buf 'repl-hist-stash)
      (desktop-skip! buf 'repl-hist-prefix)
      ;; A remap, not a key: it catches <up>, C-p, and whatever else the user
      ;; bound to the motion, which is how the list modes do it. The arrows
      ;; mean the history at the prompt, typing means typing at the prompt, and
      ;; a delete stops at it.
      (local-remap*! buf "previous-line" "scheme-repl-up")
      (local-remap*! buf "next-line" "scheme-repl-down")
      (local-remap*! buf "self-insert-command" "scheme-repl-self-insert")
      (local-remap*! buf "delete-backward-char" "scheme-repl-backward-delete")
      (local-remap*! buf "paredit--key-DEL" "scheme-repl-backward-delete")
      (repl--sync! buf))))

(mode-keys! "scheme-repl-mode"
  '(("RET" "scheme-repl-return")
    ("C-j" "scheme-repl-newline")
    ("C-a" "scheme-repl-beginning-of-input")
    ("M-p" "scheme-repl-previous-input")
    ("M-n" "scheme-repl-next-input")
    ("M-<up>" "scheme-repl-previous-matching-input")
    ("M-<down>" "scheme-repl-next-matching-input")
    ("C-c C-p" "scheme-repl-previous-prompt")
    ("C-c C-n" "scheme-repl-next-prompt")
    ("C-c M-r" "scheme-repl-search-history")
    ("C-c C-u" "scheme-repl-kill-input")
    ("C-c M-o" "scheme-repl-clear")
    ("C-c C-z" "scheme-repl")))

;;; One REPL is a session: the names you defined in it, the value in *1, the
;;; transcript you are reading. A second one is a second session, and M-x repl
;;; always opens one. They share the history ring, because a form you ran is a
;;; form you ran, whichever buffer you ran it in.

(define (scheme-repl-buffer? buf)
  (equal? (buffer-local buf 'mode-name) "scheme-repl-mode"))

;; every REPL, the one used last first. buffer-read-many, so a sleeping REPL
;; stays asleep to answer.
(define (scheme-repl-buffers)
  (map car
       (filter (lambda (row) (equal? (cadr row) "scheme-repl-mode"))
               (buffer-read-many (buffer-list-mru) '() '(mode-name)))))

(define (repl--fresh-name)
  (if (not (buffer-known? *scheme-repl-buffer*))
      *scheme-repl-buffer*
      (let loop ((n 2))
        (let ((name (string-append *scheme-repl-buffer* "<" (number->string n) ">")))
          (if (buffer-known? name) (loop (+ n 1)) name)))))

(define (scheme-repl-new!)
  (let ((buf (repl--fresh-name)))
    (buffer-create buf)
    (with-current-buffer buf (lambda () (set-mode! "scheme-repl-mode")))
    buf))

;; the REPL a source buffer means: the one it used last, else a new one
(define (scheme-repl-buffer)
  (let ((open (scheme-repl-buffers)))
    (if (pair? open) (car open) (scheme-repl-new!))))

(define (repl--focus! buf)
  (select-window! (or (window-showing buf) (display-buffer-other-window! buf))))

(define-command "repl"
  "Open a new Scheme REPL buffer"
  (lambda ()
    (let* ((here (current-buffer))
           (buf (scheme-repl-new!)))
      (buffer-set-local! buf 'repl-from here)
      (repl--focus! buf))))

(define-command "scheme-repl"
  "Go to the Scheme REPL you used last, or from one back where you came from"
  (lambda ()
    (let ((here (current-buffer)))
      (if (scheme-repl-buffer? here)
          (let ((back (buffer-local here 'repl-from)))
            (if (and back (buffer-exists? back))
                (repl--focus! back)
                (message "This REPL has nowhere to go back to")))
          (let ((buf (scheme-repl-buffer)))
            (buffer-set-local! buf 'repl-from here)
            (buffer-goto! buf (buffer-size buf))
            (repl--focus! buf))))))

;; The other half of a REPL: the definition you are reading, run where you can
;; keep it. C-x C-e evaluates and echoes; this leaves the form in the
;; transcript and in the history, which is where the next edit of it comes
;; from.
(define-command "scheme-repl-send-defun"
  "Run the definition at point in the Scheme REPL you used last"
  (lambda ()
    (let* ((here (current-buffer))
           (line (car (buffer-line-at-point here)))
           (src (code-read here line)))
      (if (not (and (string? src) (not (equal? (string-trim src) ""))))
          (message "No definition at point")
          (let ((buf (scheme-repl-buffer)))
            (buffer-set-local! buf 'repl-from here)
            (repl-set-input! buf (string-trim src))
            (repl-eval! buf (string-trim src))
            (display-buffer-other-window! buf))))))

(mode-keys! "scheme-mode"
  '(("C-c C-z" "scheme-repl")
    ("C-c C-e" "scheme-repl-send-defun")))

(category! 'code)
(effects! '(pure))
(public! 'repl--complete?
  "(repl--complete? TEXT) — #t when TEXT is one or more whole forms, so RET may run it")
(effects! '(write))
(public! 'scheme-repl-buffer
  "(scheme-repl-buffer) — the Scheme REPL used last, or a new one; in its mode, not displayed")
(public! 'scheme-repl-new!
  "(scheme-repl-new!) — a new Scheme REPL buffer, in its mode, not displayed")
(public! 'scheme-repl-buffers
  "(scheme-repl-buffers) — every open Scheme REPL buffer, the one used last first")
(public! 'scheme-repl-buffer?
  "(scheme-repl-buffer? BUF) — #t when BUF is a Scheme REPL")
(public! 'repl-input
  "(repl-input BUF) — the form standing at the REPL prompt")
(public! 'repl-set-input!
  "(repl-set-input! BUF TEXT) — put TEXT at the REPL prompt, for the user to edit")
(effects! '(write execute))
(public! 'repl-eval!
  "(repl-eval! BUF SRC) — run SRC, land its value in the transcript and in *1")
