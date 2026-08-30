;;; mode-toggle-test.scm --- a mode toggles from the modeline.
;;;
;;; The modeline names the major mode; the expanded modeline names the
;;; minor modes. Both send "mode:NAME" through the one click gate,
;;; ui-command!, and the echo area is the modeline's other half.
;;;
;;; Four tests stay in ExUnit: they read a rendered window, or a grammar
;;; the buffer holds through Buffer.

(domain! 'testing)
(effects! '(write))

(define t--mt-buf "zz-mode-toggle")

;; What the click leaves in the echo area. The message also lands in
;; *Messages*, and reading that needs no rendered frame.
(define (t--mt-click! mode)
  (let ((mark (string-length (messages-text))))
    (with-current-buffer t--mt-buf
      (lambda () (ui-command! (string-append "mode:" mode) #f)))
    (let ((said (messages-text)))
      (substring said mark (string-length said)))))

(deftest 'a-minor-mode-toggles-off-and-on-and-the-echo-states-each-result
  "the click is a toggle, and it says which way it went"
  (lambda ()
    (test-buffer! t--mt-buf "alpha\n")
    (with-current-buffer t--mt-buf (lambda () (run-command "visual-line-mode")))
    (check-true! (minor-mode-on? t--mt-buf "visual-line-mode") "the mode is on")

    (check-contains! (t--mt-click! "visual-line-mode") "visual-line-mode disabled" "off")
    (check-false! (minor-mode-on? t--mt-buf "visual-line-mode") "and it is off")

    (check-contains! (t--mt-click! "visual-line-mode") "visual-line-mode enabled" "on")
    (check-true! (minor-mode-on? t--mt-buf "visual-line-mode") "and it is on again")

    (disable-minor-mode! t--mt-buf "visual-line-mode")
    (buffer-kill! t--mt-buf)))

(deftest 'a-buffer-with-no-file-has-no-mode-to-derive
  "Fundamental is not a mode you can click into"
  (lambda ()
    (test-buffer! t--mt-buf "alpha\n")
    (check-contains! (t--mt-click! "Fundamental") "no mode for this buffer" "it says so")
    (check-false! (buffer-local t--mt-buf 'mode-name) "and sets nothing")
    (buffer-kill! t--mt-buf)))

(deftest 'a-command-for-another-mode-enters-it
  "it does not leave the current one first"
  (lambda ()
    (test-buffer! t--mt-buf "<p>hi</p>\n")
    (with-current-buffer t--mt-buf (lambda () (run-command "elixir-mode")))
    (check-contains! (t--mt-click! "html-mode") "html-mode on" "the report")
    (check-equal! (buffer-local t--mt-buf 'mode-name) "html-mode" "the mode")
    (check-equal! (buffer-local t--mt-buf 'ts-lang) "html" "and its grammar")
    (buffer-kill! t--mt-buf)))

(deftest 'text-mode-is-a-mode-like-any-other-so-it-leaves-too
  "clicking the mode you are in takes you out of it"
  (lambda ()
    (test-buffer! t--mt-buf "alpha\n")
    (with-current-buffer t--mt-buf (lambda () (set-mode! "text-mode")))
    (check-contains! (t--mt-click! "text-mode") "text-mode off" "the report")
    (check-false! (buffer-local t--mt-buf 'mode-name) "and the mode is gone")
    (buffer-kill! t--mt-buf)))
