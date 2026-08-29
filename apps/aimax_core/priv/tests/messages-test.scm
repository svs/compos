;;; messages-test.scm --- Structured message log policy.

(domain! 'testing)
(effects! '(read write))

(deftest 'messages-record-level-and-source-context
  "message records its level, source buffer, and source group"
  (lambda ()
    (messages-clear!)
    (let* ((buf "*messages-test-source*")
           (group (group-record-create! "messages-test-group")))
      (buffer-create buf)
      (buffer-add-group! buf group)
      (with-current-buffer buf
        (lambda () (message "structured warning" 'warning)))
      (let ((row (car (messages-events))))
        (check-equal! (plist-get row 'level) "warning" "the row keeps its level")
        (check-equal! (plist-get row 'source) buf "the row keeps its source buffer")
        (check-equal! (plist-get row 'group) "messages-test-group"
                      "the row keeps its source group"))
      (buffer-kill! buf)
      (group-dissolve! group))))

(deftest 'view-messages-builds-the-emacs-named-list
  "view-messages gives most space to the colored message"
  (lambda ()
    (messages-clear!)
    (message "ordinary event" 'info)
    (message "failed event" 'error)
    (run-command "view-messages")
    (check-equal! (current-buffer) "*Messages*" "the command keeps the Emacs buffer name")
    (check-equal! (buffer-local "*Messages*" 'mode-name)
                  "messages-mode" "the buffer records its mode")
    (check-true! (string-contains? (buffer-text "*Messages*") "SOURCE")
                 "the list shows one source column")
    (check-false! (string-contains? (buffer-text "*Messages*") "LEVEL")
                  "the list does not spend space on a level column")
    (check-false! (string-contains? (buffer-text "*Messages*") "TIME")
                  "the list does not spend space on time")
    (check-true! (string-contains? (buffer-text "*Messages*") "failed event")
                 "the list renders message text")))

(deftest 'messages-cells-use-group-source-and-level-color
  "the source prefers the group and the message color carries the level"
  (lambda ()
    (let ((cells
            (messages--cells "*unused*"
              (list 'level "error" 'source "buffer.scm"
                    'group "editor" 'project "ai-max.el" 'text "failed"))))
      (check-equal! (length cells) 2 "the row has only source and message")
      (check-equal! (car (car cells)) "editor" "the source shows the group")
      (check-equal! (car (car (cdr cells))) "failed" "the message keeps its text")
      (check-equal! (car (cdr (car (cdr cells)))) "alert"
                    "the message uses the error color"))))

(deftest 'messages-level-filter-narrows-the-list
  "the messages list filters exact log levels"
  (lambda ()
    (messages-clear!)
    (message "keep this error" 'error)
    (message "hide this detail" 'debug)
    (run-command "view-messages")
    (list-filter-push! "*Messages*" '("level" "error"))
    (check-true! (string-contains? (buffer-text "*Messages*") "keep this error")
                 "the selected level remains")
    (check-false! (string-contains? (buffer-text "*Messages*") "hide this detail")
                  "other levels leave the view")
    (list-filter-clear! "*Messages*")))
