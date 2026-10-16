;;; messages-test.scm --- Structured message log policy.

(domain! 'testing)
(effects! '(read write))

(deftest 'messages-record-level-and-source-context
  "message records its level, source buffer, and source group"
  (lambda ()
    (messages-clear!)
    (with-fresh-group "messages-test-group"
      (lambda (group)
        (let ((buf "*messages-test-source*"))
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
          (group-dissolve! group))))))

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
    (check-true! (string-contains? (buffer-text "*Messages*") "LEVEL")
                 "the level column carries the colour code")
    (check-true! (string-contains? (buffer-text "*Messages*") "failed event")
                 "the list renders message text")))

(deftest 'the-messages-list-puts-the-newest-line-on-top
  "the log arrives oldest first and the list turns it over"
  (lambda ()
    (messages-clear!)
    (message "older event" 'info)
    (message "newer event" 'info)
    (run-command "view-messages")
    (let* ((at (lambda (q) (with-current-buffer "*Messages*"
                             (lambda () (isearch-matches q)))))
           (newer (at "newer event"))
           (older (at "older event")))
      (check-true! (and (pair? newer) (pair? older))
                   "both messages are drawn")
      (check-true! (< (car (car newer)) (car (car older)))
                   "the newest message is the higher row"))))

(deftest 'the-messages-list-wears-a-smaller-face
  "a log is read in bulk, so *Messages* sits a step below the default size"
  (lambda ()
    (messages-clear!)
    (message "a row" 'info)
    (check-equal! (buffer-local "*Messages*" 'text-scale) messages-text-scale
                  "the buffer carries the configured step")))

(deftest 'the-messages-list-pins-its-keys-in-the-keys-bar
  "the key bar is the keys bar at the window's foot, not a header line"
  (lambda ()
    (messages-clear!)
    (message "a row" 'info)
    (run-command "view-messages")
    (let ((blocks (buffer-local "*Messages*" 'footer-line-blocks)))
      (check-true! (pair? blocks) "the footer carries blocks")
      (check-equal! (plist-get (car blocks) 'tag) "c-keys-bar"
                    "and those blocks are the keys bar"))))

(deftest 'messages-cells-name-the-buffer-and-colour-the-level
  "the source is the buffer that spoke, not its group"
  (lambda ()
    (let ((cells
            (messages--cells "*unused*"
              (list 'level "error" 'source "buffer.scm"
                    'group "editor" 'project "compos.el" 'text "failed"))))
      (check-equal! (length cells) 5 "time, level, mode, source, message")
      (check-equal! (car (nth 1 cells)) "error" "the level chip names the level")
      (check-equal! (nth 1 (nth 1 cells)) "error" "and wears the error colour")
      (check-equal! (car (nth 3 cells)) "buffer.scm"
                    "the source names the buffer, not the group")
      (check-equal! (car (nth 4 cells)) "failed" "the message keeps its text")
      (check-equal! (nth 1 (nth 4 cells)) "error"
                    "the message text takes the error colour too"))))

(deftest 'the-mode-column-reads-the-mode-the-buffer-spoke-in
  "the mode is read on the message, not asked of the buffer on every draw"
  (lambda ()
    (messages-clear!)
    (let ((buf "*messages-mode-test*"))
      (buffer-create buf)
      (with-current-buffer buf (lambda () (set-mode! "scheme-mode")))
      (with-current-buffer buf (lambda () (message "from a scheme buffer" 'info)))
      (let* ((row (car (messages-events)))
             (label (messages--mode-label row)))
        (check-true! (string-contains? label "scheme")
                     "the column names the mode")
        (check-false! (string-contains? label "-mode")
                      "without the five characters every row would repeat")
        (check-true! (string-contains? label (mode-icon "scheme-mode"))
                     "and carries the mode icon"))
      ;; the buffer is gone, and the label still answers
      (buffer-kill! buf)
      (check-true! (string-contains? (messages--mode-label (car (messages-events)))
                                     "scheme")
                   "a killed buffer's mode is still the mode it spoke in"))))

(deftest 'an-info-message-puts-no-face-on-its-text
  "only the chip is coloured on the ordinary case, so a colour means something.
   The text wears no face at all: the default face is where the buffer's own
   size and background come from, and a span wearing it re-states both and
   ignores the text scale."
  (lambda ()
    (let ((cells (messages--cells "*unused*"
                   (list 'level "info" 'source "a.scm" 'group "" 'project ""
                         'text "ordinary"))))
      (check-equal! (nth 1 (nth 1 cells)) "accent" "the info chip is the accent")
      (check-false! (nth 1 (nth 4 cells))
                    "and the text wears no face"))
    (let ((cells (messages--cells "*unused*"
                   (list 'level "debug" 'source "a.scm" 'group "" 'project ""
                         'text "detail"))))
      (check-equal! (nth 1 (nth 1 cells)) "dim" "debug is grey")
      (check-equal! (nth 1 (nth 4 cells)) "dim" "in the chip and in the text"))))

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

(deftest 'messages-buffer-is-the-list-from-the-start
  "*Messages* wears messages-mode and is read-only before anyone runs view-messages"
  (lambda ()
    (messages-clear!)
    (message "first row" 'info)
    (check-equal! (buffer-local "*Messages*" 'mode-name) "messages-mode" "the mode is on")
    (check-true! (buffer-read-only? "*Messages*") "the list is read-only")
    (list-refresh! "*Messages*")
    (check-true! (string-contains? (buffer-text "*Messages*") "first row")
                 "the list draws the row")))

(deftest 'a-killed-messages-buffer-returns-as-the-list
  "after buffer-kill!, the next message makes *Messages* again in messages-mode"
  (lambda ()
    (messages-clear!)
    (when (buffer-exists? "*Messages*") (buffer-kill! "*Messages*"))
    (message "after the kill" 'info)
    (check-true! (buffer-exists? "*Messages*") "the buffer is back")
    (check-equal! (buffer-local "*Messages*" 'mode-name) "messages-mode" "in messages-mode")
    (check-true! (buffer-read-only? "*Messages*") "and read-only")
    (list-refresh! "*Messages*")
    (check-true! (string-contains? (buffer-text "*Messages*") "after the kill")
                 "with the row")))

(deftest 'a-message-redraws-the-shown-list
  "a message while *Messages* is in a window appears with no refresh"
  (lambda ()
    (messages-clear!)
    (run-command "view-messages")
    (message "live row" 'info)
    (check-true! (string-contains? (buffer-text "*Messages*") "live row")
                 "the shown list follows the log")))

(deftest 'a-watch-reacts-to-the-messages-its-grammar-matches
  "the grammar's captures reach the reaction; other messages do not"
  (lambda ()
    (messages-clear!)
    (let ((seen '()))
      (messages-watch! "test-deploys" '(level "error" match "deploy ([a-z-]+)")
        (lambda (row caps) (set! seen (cons (nth 1 caps) seen))))
      (message "deploy web-front" 'error)
      (message "deploy web-front" 'info)
      (message "nothing here" 'error)
      (messages-unwatch! "test-deploys")
      (check-equal! seen '("web-front")
                    "only the matching level and text fired, with its capture")
      (message "after the unwatch" 'error)
      (check-equal! seen '("web-front") "and an unwatched name stops firing"))))

(deftest 'an-empty-grammar-watches-every-message
  "an absent field matches anything"
  (lambda ()
    (messages-clear!)
    (let ((n 0))
      (messages-watch! "test-all" '() (lambda (row caps) (set! n (+ n 1))))
      (message "one" 'info)
      (message "two" 'debug)
      (messages-unwatch! "test-all")
      (check-equal! n 2 "both messages reached the watch"))))

(deftest 'a-reaction-that-logs-does-not-re-enter-the-watches
  "the dispatch is closed while a reaction runs"
  (lambda ()
    (messages-clear!)
    (let ((n 0))
      (messages-watch! "test-loop" '()
        (lambda (row caps)
          (set! n (+ n 1))
          (when (< n 10) (message "the reaction's own message" 'info))))
      (message "the cause" 'info)
      (messages-unwatch! "test-loop")
      (check-equal! n 1 "the reaction ran once, not forever"))))

(deftest 'a-raising-reaction-does-not-stop-the-log
  "one bad watch cannot close the dispatch on the others"
  (lambda ()
    (messages-clear!)
    (let ((n 0))
      (messages-watch! "test-bad" '() (lambda (row caps) (error "boom")))
      (messages-watch! "test-good" '() (lambda (row caps) (set! n (+ n 1))))
      (message "first" 'info)
      (message "second" 'info)
      (messages-unwatch! "test-bad")
      (messages-unwatch! "test-good")
      (check-equal! n 2 "the good watch kept running")
      (check-true! (string-contains? (messages-text) "second")
                   "and the log kept recording"))))

(deftest 'a-narrow-messages-window-keeps-the-message-and-drops-the-provenance
  "the message is what the reader came for; mode and source go first"
  (lambda ()
    (let* ((row (list 'level "error" 'source "buffer.scm" 'group "editor"
                      'project "compos.el" 'text "failed"))
           (wide (messages--cells "*unused*" row))
           (narrow (messages--narrow-cells "*unused*" row)))
      (check-equal! (length wide) 5 "wide keeps time, level, mode, source, message")
      (check-equal! (length narrow) 3 "narrow keeps time, level, message")
      (check-equal! (car (nth 2 narrow)) "failed"
                    "and the message is still the last column")
      (check-equal! (nth 1 (nth 1 narrow)) "error"
                    "with its level colour intact"))))
