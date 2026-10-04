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

(define onboarding-welcome-text
  "Welcome to compos.

The window beside this one is your guide. It is a chat: type in it and
press RET to send.

This window is the stage. The guide puts here what each step is about:
a file to edit, a help page, a list of buffers. You can work in it.

C-x o moves the focus between the two windows.
C-g stops anything that waits for you.
")

(define (onboarding--welcome!)
  (unless (buffer-exists? *onboarding-welcome*)
    (buffer-create *onboarding-welcome*)
    (buffer-append! *onboarding-welcome* onboarding-welcome-text))
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
