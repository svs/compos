;;; onboarding.scm --- the first-run app: a guide chat and a stage window beside it.
;;;
;;; M-x onboarding opens its own group with two windows. The chat is the
;;; guide: it loads the onboarding skill and teaches one step per turn. The
;;; other window is the stage. The guide changes what the stage shows as the
;;; lesson moves on, and the focus stays where the user put it.

(domain! 'learning)
(effects! '(write display))

(define *onboarding-group* "getting-started")
(define *onboarding-welcome* "*onboarding*")


;;; The stage page. onboarding-mode draws one step: its title, its text,
;;; and its keys. Each step is a minor mode, onboarding-step-N-mode, whose
;;; keymap holds the keys the step teaches. The page shows that keymap, and
;;; the keys bar shows it beside the onboarding-mode map.

(define *onboarding-steps* '())

(define (onboarding-step-mode n)
  (string-append "onboarding-step-" (number->string n) "-mode"))

(define (define-onboarding-step! n title text keys)
  "Step N of the stage page. TEXT marks a key as `KEY`; KEYS are (KEY COMMAND LABEL)."
  (let ((mode (onboarding-step-mode n)))
    (register-minor-mode! mode (lambda (buf) #t) (lambda (buf) #t))
    (minor-mode-keys! mode (map (lambda (k) (list (car k) (cadr k))) keys))
    (set! *onboarding-steps*
          (cons (list n title text keys)
                (filter (lambda (s) (not (equal? (car s) n))) *onboarding-steps*)))
    mode))

(define (onboarding--step n) (assoc n *onboarding-steps*))

(define (onboarding--last-step)
  (apply max (cons 1 (map car *onboarding-steps*))))

(define *onboarding-mode-keys*
  '(("n" "onboarding-next-step" "Next step")
    ("p" "onboarding-previous-step" "Previous step")))

(define (onboarding--segs line)
  ;; `KEY` in the text draws as a pressable key.
  (let loop ((parts (string-split line "`")) (key? #f) (out '()))
    (cond ((null? parts) (reverse out))
          ((equal? (car parts) "") (loop (cdr parts) (not key?) out))
          (else (loop (cdr parts) (not key?)
                      (cons (list (if key? "c-action-key" "") (car parts)) out))))))

(define (onboarding--pairs keys)
  (map (lambda (k) (list (car k) (caddr k))) keys))

(define (onboarding--draw! buf)
  (let* ((n (or (buffer-local buf 'onboarding-step) 1))
         (step (or (onboarding--step n) (list n "" "" '())))
         (title (list-ref step 1))
         (text (list-ref step 2))
         (keys (list-ref step 3)))
    (buffer-set-read-only! buf #f)
    (buffer-set-text! buf
      (string-append title "\n\n" text "\n\n"
                     (string-join (map (lambda (k) (string-append (car k) "  " (caddr k))) keys)
                                  "\n")
                     "\n"))
    (buffer-set-read-only! buf #t)
    (buffer-set-locals! buf
      (list 'render-mode "blocks"
            'render-root (list 'tag "onboarding-page")
            'render-blocks
            (append
              (list (list 'tag "c-headerline" 'class "onb-title"
                          'text (string-append "Step " (number->string n) " of "
                                               (number->string (onboarding--last-step))
                                               ": " title)))
              (map (lambda (p) (component 'ui/row (list 'segs (onboarding--segs p))))
                   (string-split text "\n\n"))
              (list (component 'ui/keymap (list 'keys keys))))
            'footer-line-blocks
            (list (component 'ui/keys-bar
                    (list 'main (append (onboarding--pairs keys)
                                        (onboarding--pairs *onboarding-mode-keys*))
                          'grids (list (list (onboarding-step-mode n) (onboarding--pairs keys))
                                       (list "onboarding-mode"
                                             (onboarding--pairs *onboarding-mode-keys*))))))))
    buf))

(define (onboarding-step! buf n)
  "Show step N on the stage page BUF, with its step mode on. Answer the step shown."
  (when (onboarding--step n)
    (for-each (lambda (s)
                (let ((mode (onboarding-step-mode (car s))))
                  (when (minor-mode-on? buf mode) (disable-minor-mode! buf mode))))
              *onboarding-steps*)
    (buffer-set-local! buf 'onboarding-step n)
    (enable-minor-mode! buf (onboarding-step-mode n))
    (onboarding--draw! buf))
  (buffer-local buf 'onboarding-step))

(define-mode "onboarding-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'desktop-skip-locals
        '(render-root render-blocks footer-line-blocks))
      (onboarding-step! buf (or (buffer-local buf 'onboarding-step) 1))))
  'doc "The onboarding stage page, one step at a time. The page shows the keys the step teaches, and they work here. `n` goes to the next step and `p` to the one before.")
(mode-parent! "onboarding-mode" "special-mode")
(mode-keys! "onboarding-mode"
  (map (lambda (k) (list (car k) (cadr k))) *onboarding-mode-keys*))

(define-command "onboarding-next-step" "Go to the next onboarding step"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (+ 1 (or (buffer-local buf 'onboarding-step) 1))))
      (if (onboarding--step n)
          (onboarding-step! buf n)
          (message "This is the last step")))))

(define-command "onboarding-previous-step" "Go to the previous onboarding step"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (- (or (buffer-local buf 'onboarding-step) 1) 1)))
      (if (onboarding--step n)
          (onboarding-step! buf n)
          (message "This is the first step")))))

(define-onboarding-step! 1 "Two windows"
  "The window beside this one is your guide. It is a chat: type in it and press `RET` to send.

This window is the stage. The guide puts here what each step is about, and you can work in it.

`C-x o` moves the focus between the two windows. `C-g` stops anything that waits for you."
  '(("C-x o" "other-window" "Move to the other window")
    ("C-g" "keyboard-quit" "Stop what waits for you")))

(define (onboarding--welcome!)
  (unless (buffer-exists? *onboarding-welcome*)
    (buffer-create *onboarding-welcome*))
  (unless (equal? (buffer-local *onboarding-welcome* 'mode-name) "onboarding-mode")
    (with-current-buffer *onboarding-welcome*
      (lambda () (set-mode! "onboarding-mode"))))
  *onboarding-welcome*)

(define (onboarding-group)
  "The onboarding group id, or #f before the first start."
  (group-resolve-id *onboarding-group*))

(define (onboarding-chat)
  "The guide chat, or #f before the first start."
  (let ((id (onboarding-group)))
    (and id (group-chat id))))

(define (onboarding--stage)
  ;; The window the stage lives in: the one start! recorded, or else the
  ;; first window of the frame that does not show the guide.
  (let* ((chat (onboarding-chat))
         (w (and chat (buffer-local chat 'onboarding-stage))))
    (cond ((not chat) #f)
          ((and w (window-exists? w)
                (not (equal? (window-buffer w) chat))) w)
          ((window-showing chat)
           (let ((others (filter (lambda (r) (not (equal? (cadr r) chat)))
                                 (window-list))))
             (and (pair? others)
                  (begin (buffer-set-local! chat 'onboarding-stage (caar others))
                         (caar others)))))
          (else #f))))

(define (onboarding-stage-buffer)
  "The buffer the stage shows, or #f when the onboarding windows are not in view."
  (with-frame-windows
    (lambda ()
      (let ((w (onboarding--stage)))
        (and w (window-buffer w))))))

(define (onboarding-show! buf)
  "Show BUF on the stage; the focus does not move. Answer BUF, or #f."
  (with-frame-windows
    (lambda ()
      (let ((w (onboarding--stage)))
        (and w (buffer-known? buf) (window-set-buffer! w buf) buf)))))

(define (onboarding-stage-run! command)
  "Run COMMAND on the stage, then give the focus back. Answer what the stage shows."
  ;; A command that shows its result in the other window would cover the
  ;; guide; put the guide back and move the result to the stage.
  (with-frame-windows
    (lambda ()
      (let ((w (onboarding--stage))
            (back (active-window)))
        (when w
          (let ((before (window-buffer back)))
            (select-window! w)
            (run-command command)
            (when (window-exists? back)
              (let ((after (window-buffer back)))
                (unless (or (equal? back w) (equal? after before))
                  (window-set-buffer! back before)
                  (window-set-buffer! w after)))
              (select-window! back))))
        (and w (window-buffer w))))))

(define (onboarding--help-on-stage? name alist)
  ;; Help asked for on the stage opens on the stage, where q closes it.
  ;; The other window is the guide, and help there would cover it.
  (and (equal? name *help-buffer*)
       (let ((w (onboarding--stage)))
         (and w (equal? w (active-window))))))

(add-display-rule! onboarding--help-on-stage? 'same-window)

(define (onboarding-start!)
  "Open the onboarding group: the guide chat, and the stage beside it."
  (let* ((id (or (onboarding-group)
                 (group-record-create! *onboarding-group*)))
         (welcome (onboarding--welcome!)))
    (buffer-add-group! welcome id)
    (let ((chat (group-chat id)))
      (switch-to-buffer-in-group! chat)
      (delete-other-windows!)
      (split-window! 'h 0.45)
      (let ((stage (car (car (filter (lambda (r) (not (equal? (car r) (active-window))))
                                     (window-list))))))
        (window-set-buffer! stage welcome)
        (buffer-set-local! chat 'onboarding-stage stage))
      (unless (buffer-local chat 'onboarding-started)
        (buffer-set-local! chat 'onboarding-started #t)
        (with-current-buffer chat
          (lambda ()
            (end-of-buffer!)
            (insert! "/onboarding")
            (run-command "agent-send"))))
      chat)))

;;;###autoload
(define-command "onboarding"
  "Learn compos with a guide: a chat, and a stage window beside it"
  (lambda () (onboarding-start!)))

(category! 'learning)
(public! 'onboarding-start!
  "(onboarding-start!) — open the onboarding group and start the guide")
(public! 'onboarding-chat
  "(onboarding-chat) — the guide chat, or #f")
(public! 'onboarding-stage-buffer
  "(onboarding-stage-buffer) — the buffer the stage window shows, or #f")
(public! 'onboarding-show!
  "(onboarding-show! BUF) — show BUF on the stage; the focus does not move")
(public! 'onboarding-stage-run!
  "(onboarding-stage-run! COMMAND) — run an M-x command on the stage and give the focus back")
(public! 'onboarding-step!
  "(onboarding-step! BUF N) — show step N on the stage page, with onboarding-step-N-mode on")
(public! 'define-onboarding-step!
  "(define-onboarding-step! N TITLE TEXT KEYS) — a stage step; `KEY` in TEXT draws as a key, KEYS are (KEY COMMAND LABEL)")
