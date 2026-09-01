;;; register.scm --- Emacs registers: a position, a text, a window arrangement.
;;;
;;; A register is one character naming a slot. C-x r SPC saves point,
;;; C-x r j jumps back; C-x r s saves the region's text, C-x r i inserts
;;; it; C-x r w saves the frame's windows, and C-x r j restores them. The
;;; registers persist with the desktop.

(domain! 'editing)
(effects! '(write))

(define *registers* '())    ; ((NAME KIND VALUE ...) ...)

(persist-global! 'registers
  (lambda () *registers*)
  (lambda (v) (set! *registers* v)))

(define (register-set! name value)
  (set! *registers*
    (cons (cons name value)
          (remove (lambda (e) (equal? (car e) name)) *registers*)))
  name)

(define (register-get name)
  (let ((e (assoc name *registers*))) (and e (cdr e))))

(define (register-names) (map car *registers*))

(define (register--kind v) (and (pair? v) (car v)))

;; what a register holds, in a line
(define (register-describe name)
  (let ((v (register-get name)))
    (cond ((not v) "empty")
          ((equal? (car v) 'point)
           (string-append "point " (number->string (nth 2 v)) " in " (nth 1 v)))
          ((equal? (car v) 'text)
           (let ((t (nth 1 v)))
             (string-append "text: "
                            (if (> (string-length t) 40) (string-append (substring t 0 40) "...") t))))
          ((equal? (car v) 'window) "a window arrangement")
          (else "?"))))

(define (register--prompt prompt k)
  (read-char prompt (lambda (ch) (when ch (k ch)))))

(define (point-to-register! name)
  (register-set! name (list 'point (current-buffer) (point)))
  (message (string-append "Point saved in register " name)))

(define (window-configuration-to-register! name)
  (register-set! name (list 'window (window-tree)))
  (message (string-append "Windows saved in register " name)))

(define (copy-to-register! name text)
  (register-set! name (list 'text text))
  (message (string-append "Copied to register " name)))

(define (append-to-register! name text)
  (let ((v (register-get name)))
    (register-set! name
      (list 'text (string-append (if (and v (equal? (car v) 'text)) (nth 1 v) "") text)))
    (message (string-append "Appended to register " name))))

(define (jump-to-register! name)
  (let ((v (register-get name)))
    (cond ((not v) (message (string-append "Register " name " is empty")))
          ((equal? (car v) 'point)
           (if (buffer-known? (nth 1 v))
               (begin (switch-to-buffer! (nth 1 v)) (goto-char! (nth 2 v)))
               (message (string-append "Buffer " (nth 1 v) " is gone"))))
          ((equal? (car v) 'window) (window-tree-set! (nth 1 v)))
          (else (message (string-append "Register " name " holds text; C-x r i inserts it"))))))

(define (insert-register! name)
  (let ((v (register-get name)))
    (if (and v (equal? (car v) 'text))
        (insert! (nth 1 v))
        (message (string-append "Register " name " holds no text")))))

(define-command "point-to-register" "Save point and the buffer in a register"
  (lambda () (register--prompt "Point to register: " point-to-register!)))

(define-command "jump-to-register" "Go to a saved point, or restore saved windows"
  (lambda () (register--prompt "Jump to register: " jump-to-register!)))

(define-command "copy-to-register" "Save the region's text in a register"
  (interactive 'r)
  (lambda (s e)
    (let ((text (buffer-substring s e)))
      (register--prompt "Copy to register: " (lambda (name) (copy-to-register! name text))))))

(define-command "append-to-register" "Append the region's text to a register"
  (interactive 'r)
  (lambda (s e)
    (let ((text (buffer-substring s e)))
      (register--prompt "Append to register: " (lambda (name) (append-to-register! name text))))))

(define-command "insert-register" "Insert a register's text at point"
  (lambda () (register--prompt "Insert register: " insert-register!)))

(define-command "window-configuration-to-register" "Save the frame's windows in a register"
  (lambda () (register--prompt "Windows to register: " window-configuration-to-register!)))

(define-command "view-register" "Say what a register holds"
  (lambda ()
    (register--prompt "View register: "
      (lambda (name) (message (string-append "Register " name ": " (register-describe name)))))))

(global-set-key "C-x r SPC" "point-to-register")
(global-set-key "C-x r C-SPC" "point-to-register")
(global-set-key "C-x r j" "jump-to-register")
(global-set-key "C-x r s" "copy-to-register")
(global-set-key "C-x r x" "copy-to-register")
(global-set-key "C-x r i" "insert-register")
(global-set-key "C-x r +" "append-to-register")
(global-set-key "C-x r w" "window-configuration-to-register")
(global-set-key "C-x r v" "view-register")

(public! 'register-set! "(register-set! NAME VALUE) — VALUE is (point BUF POS), (text STR), or (window TREE)")
(public! 'register-get "(register-get NAME) — the register's value, or #f")
(public! 'register-names "(register-names) — every register that holds something")
(public! 'register-describe "(register-describe NAME) — what the register holds, in a line")
(public! 'point-to-register! "(point-to-register! NAME) — save point and the buffer")
(public! 'jump-to-register! "(jump-to-register! NAME) — go to a saved point, or restore saved windows")
(public! 'copy-to-register! "(copy-to-register! NAME TEXT) — save TEXT")
(public! 'insert-register! "(insert-register! NAME) — insert the saved text at point")
(public! 'window-configuration-to-register! "(window-configuration-to-register! NAME) — save the frame's windows")
