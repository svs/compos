;;; editing-state-test.scm --- the movement state and the editing state of a buffer.
;;;
;;; A landing starts in the movement state. A command enters the editing
;;; state; keyboard-quit and the directional commands do not. A read-only buffer never
;;; enters it. The tests call the hook functions with a command name and
;;; read the state; no test names a key.

(domain! 'testing)
(effects! '(write))

(define t--es-a "*zz-es-a*")
(define t--es-b "*zz-es-b*")

(define (t--es-setup!)
  (delete-other-windows!)
  (for-each (lambda (b)
              (unless (buffer-exists? b) (buffer-create b))
              (buffer-set-read-only! b #f)
              (editing-state-off! b))
            (list t--es-a t--es-b))
  (switch-to-buffer! t--es-a)
  (editing--check-landing!))

(deftest 'a-command-enters-the-editing-state-and-keyboard-quit-leaves-it
  "after a command the buffer is in the editing state; after keyboard-quit it is not"
  (lambda ()
    (t--es-setup!)
    (check-equal! (editing-state? t--es-a) #f "a landing starts in the movement state")
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-a) #t "a command enters the editing state")
    (check-equal! (if (member "editing-state-map" (buffer-minor-maps t--es-a)) #t #f) #t
                  "editing-state-map is in force")
    (editing--after-command! "keyboard-quit")
    (check-equal! (editing-state? t--es-a) #f "keyboard-quit returns to the movement state")
    (check-equal! (if (member "editing-state-map" (buffer-minor-maps t--es-a)) #t #f) #f
                  "editing-state-map is gone")))

(deftest 'focus-keeps-the-movement-state
  "a focus command after a landing does not enter the editing state"
  (lambda ()
    (t--es-setup!)
    (editing--after-command! "focus-up")
    (check-equal! (editing-state? t--es-a) #f "focus changes no state")))

;; C-x 3 then a Cmd-arrow must move the focus: a window command is a
;; landing. The catalog domain says which commands are window commands.
(deftest 'a-window-command-returns-to-the-movement-state
  "after a command in the windows domain the buffer is in the movement state"
  (lambda ()
    (t--es-setup!)
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-a) #t "a command enters the editing state")
    (check-equal! (editing--window-command? "split-window-right") #t
                  "split-window-right is a window command by its catalog domain")
    (check-equal! (editing--window-command? "forward-char") #f
                  "forward-char is not a window command")
    (editing--after-command! "split-window-right")
    (check-equal! (editing-state? t--es-a) #f "a window command returns to the movement state")
    (editing--after-command! "forward-char")
    (editing--after-command! "delete-other-windows")
    (check-equal! (editing-state? t--es-a) #f "the cached answer gives the same result")))

(deftest 'a-new-landing-starts-in-the-movement-state
  "the editing state ends when the window shows another buffer"
  (lambda ()
    (t--es-setup!)
    (editing--after-command! "forward-char")
    (switch-to-buffer! t--es-b)
    (editing--check-landing!)
    (check-equal! (editing-state? t--es-b) #f "the new buffer lands in the movement state")
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-b) #t "a command in the new buffer enters the editing state")
    (switch-to-buffer! t--es-a)
    (editing--check-landing!)
    (check-equal! (editing-state? t--es-a) #f "coming back is a new landing")))

(deftest 'a-landing-in-another-frame-leaves-this-one-armed
  "each frame keeps its own landing: another frame's window change is not one here"
  (lambda ()
    (t--es-setup!)
    (editing--after-command! "forward-char")
    (set! *editing-landing* (cons (list "zz-other-frame" 1 t--es-b) *editing-landing*))
    (editing--check-landing!)
    (check-equal! (editing-state? t--es-a) #t "still armed after the other frame landed")))

(deftest 'a-read-only-buffer-stays-in-the-movement-state
  "a command in a read-only buffer does not enter the editing state"
  (lambda ()
    (t--es-setup!)
    (buffer-set-read-only! t--es-a #t)
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-a) #f "read-only: no editing state")
    (buffer-set-read-only! t--es-a #f)))

;; chat-abort with no reply in flight runs keyboard-quit inside itself.
;; The hook then sees the outer command's name, so the quit travels as a
;; flag that keyboard-quit sets.
(define-command "t--es-quit-by-proxy" "Run keyboard-quit from inside another command"
  (lambda () (run-command "keyboard-quit")))

(deftest 'a-command-that-runs-keyboard-quit-is-a-quit
  "after a command that runs keyboard-quit inside itself the buffer is in the movement state"
  (lambda ()
    (t--es-setup!)
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-a) #t "a command enters the editing state")
    (run-command "t--es-quit-by-proxy")
    (editing--after-command! "t--es-quit-by-proxy")
    (check-equal! (editing-state? t--es-a) #f "the proxy quit returns to the movement state")
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-a) #t "the quit flag does not outlive its command")))

(deftest 'editing-quit-marks-any-command-as-a-quit
  "a command that calls editing-quit! returns the buffer to the movement state"
  (lambda ()
    (t--es-setup!)
    (editing--after-command! "forward-char")
    (editing-quit!)
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-a) #f "editing-quit! makes the command a quit")))

;; A mode may refuse one of the state's maps. chat-mode refuses the caret
;; map: a chat is typed in without pause, so a buffer that held the
;; Cmd-arrows while armed would never answer the window motion again.
(deftest 'a-chat-keeps-the-cmd-arrows-for-the-window-motion
  "the caret map is in force in a plain buffer and not in a chat"
  (lambda ()
    (t--es-setup!)
    (editing--after-command! "forward-char")
    (check-equal! (if (member "editing-caret-map" (buffer-minor-maps t--es-a)) #t #f) #t
                  "a plain buffer hands the Cmd-arrows to the caret")
    (editing-state-off! t--es-a)
    (buffer-set-local! t--es-a 'mode-name "chat-mode")
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-a) #t "a chat still enters the editing state")
    (check-equal! (if (member "editing-caret-map" (buffer-minor-maps t--es-a)) #t #f) #f
                  "and keeps the Cmd-arrows on the window motion")
    (check-equal! (if (member "cua-mode-map" (buffer-minor-maps t--es-a)) #t #f) #t
                  "the Shift selections still arm there")
    (editing-state-off! t--es-a)
    (buffer-kill! t--es-a)))
