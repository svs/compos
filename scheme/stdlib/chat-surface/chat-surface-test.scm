;;; chat-surface-test.scm --- the chat interface every kind of chat shares.

(domain! 'chat)
(effects! '(write))

(define t--surface-buf "*zz-chat-surface*")
(define t--surface-sent '())

(define (t--surface-chat!)
  (set! t--surface-sent '())
  (test-buffer! t--surface-buf "")
  (buffer-set-local! t--surface-buf 'chat-history-ring '())
  (chat-surface-history-reset! t--surface-buf)
  (chat-surface! t--surface-buf
    (list 'mark 'zz-mark
          'draw (lambda (buf) (list 'items (map (lambda (s) (list 'tag "div" 'text s)) (reverse t--surface-sent))
                                    'prompt '(hint "say")))
          'send (lambda (buf text)
                  (chat-surface-clear-input! buf text)
                  (set! t--surface-sent (cons text t--surface-sent))
                  (chat-surface-redraw! buf))))
  t--surface-buf)

(deftest 'a-chat-kind-injects-its-format-and-send
  "RET hands the input to the kind's send, and the page is the kind's format around the shared transcript and input"
  (lambda ()
    (let ((buf (t--surface-chat!)))
      (with-current-buffer buf
        (lambda ()
          (insert! "hello")
          (run-command "chat-surface-send")
          (check-equal! t--surface-sent '("hello") "the kind's send got the input")
          (check-equal! (chat-surface-input-text buf) "" "and the input is empty again")
          (let ((tags (map (lambda (n) (plist-get n 'tag)) (buffer-local-value 'render-blocks buf))))
            (check-equal! tags '("c-transcript" "c-prompt") "a transcript and an input"))
          (check-equal! (buffer-local-value 'render-input buf) "zz-mark" "the input starts at the kind's mark")))
      (buffer-kill! buf))))

(deftest 'up-and-down-walk-what-was-sent-here
  "the ring is the chat's own, newest first; what you typed is the search"
  (lambda ()
    (let ((buf (t--surface-chat!)))
      (with-current-buffer buf
        (lambda ()
          (insert! "hello") (run-command "chat-surface-send")
          (insert! "world") (run-command "chat-surface-send")
          (run-command "chat-surface-history-previous")
          (check-equal! (chat-surface-input-text buf) "world" "the newest first")
          (run-command "chat-surface-history-previous")
          (check-equal! (chat-surface-input-text buf) "hello" "then the older")
          (run-command "chat-surface-history-next")
          (run-command "chat-surface-history-next")
          (check-equal! (chat-surface-input-text buf) "" "down comes back to the draft")
          (insert! "h")
          (run-command "chat-surface-history-previous")
          (check-equal! (chat-surface-input-text buf) "hello" "a typed prefix walks only what starts with it")))
      (buffer-kill! buf))))

(deftest 'stepping-and-following-the-newest
  "M-<up> leaves the bottom for an entry; past the newest the chat keeps to it again"
  (lambda ()
    (let ((buf (t--surface-chat!)))
      (with-current-buffer buf
        (lambda ()
          (insert! "a") (run-command "chat-surface-send")
          (insert! "b") (run-command "chat-surface-send")
          (run-command "chat-surface-previous-entry")
          (check-equal! (buffer-local-value 'follow-place buf) '(#t 0 1 0) "the entry before the newest at the top")
          (run-command "chat-surface-next-entry")
          (check-equal! (buffer-local-value 'follow-place buf) #f "past the newest it follows again")
          (run-command "chat-surface-to-top")
          (check-equal! (buffer-local-value 'follow-place buf) '(#t 0 #f 0) "M-< is the very top")))
      (buffer-kill! buf))))

(deftest 'a-mode-registers-its-kind
  "a buffer of a registered mode is that kind's chat without attaching a spec"
  (lambda ()
    (test-buffer! t--surface-buf "x")
    (chat-surface-kind! "zz-chat-kind-mode" (list 'mark 'zz-mark))
    (buffer-set-local! t--surface-buf 'mode-name "zz-chat-kind-mode")
    (buffer-set-local! t--surface-buf 'zz-mark 0)
    (check-equal! (chat-surface? t--surface-buf) #t "the mode's kind applies")
    (set! *chat-surface-kinds* (filter (lambda (k) (not (equal? (car k) "zz-chat-kind-mode"))) *chat-surface-kinds*))
    (buffer-kill! t--surface-buf)))
