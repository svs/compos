;;; chrome-test.scm --- chrome attachments hold no bytes and move no caret.
;;;
;;; A chrome attachment is display, not text. Point arithmetic, motion
;;; commands, and saving must behave exactly as if it were not there.

(domain! 'testing)
(effects! '(write))

(define t--chrome-buf "zz-chrome-motion.md")

(define (t--chrome! text point)
  (test-buffer! t--chrome-buf text)
  (with-current-buffer t--chrome-buf (lambda () (set-mode! "morg-mode")))
  (when (minor-mode-on? t--chrome-buf "preview-mode")
    (disable-minor-mode! t--chrome-buf "preview-mode"))
  (buffer-goto! t--chrome-buf point)
  t--chrome-buf)

(define (t--chrome-run! cmd)
  (with-current-buffer t--chrome-buf (lambda () (run-command cmd))))

(define (t--chrome-point) (buffer-point t--chrome-buf))

(deftest 'motion-walks-past-chrome-as-if-it-were-not-there
  "left and right cross a chrome boundary one byte at a time"
  (lambda ()
    (t--chrome! "abcdef\n" 2)
    (overlay-set! t--chrome-buf 'chrome
      (list (chrome-after 3 "chip" "zz-badge")))
    (t--chrome-run! "forward-char")
    (check-equal! (t--chrome-point) 3 "one byte forward, onto the boundary")
    (t--chrome-run! "forward-char")
    (check-equal! (t--chrome-point) 4 "one byte past it, never inside it")
    (t--chrome-run! "backward-char")
    (t--chrome-run! "backward-char")
    (check-equal! (t--chrome-point) 2 "and the same road back")
    (buffer-kill! t--chrome-buf)))

(deftest 'line-motion-crosses-a-chrome-bearing-line
  "up and down land where they land in a buffer with no chrome"
  (lambda ()
    (t--chrome! "alpha\nbravo\ncharlie\n" 14)
    (overlay-set! t--chrome-buf 'chrome
      (list (chrome-after 5 "chip" "zz-badge")
            (chrome-before 6 "mark" "zz-badge")))
    (t--chrome-run! "previous-line")
    (check-equal! (t--chrome-point) 8 "up keeps the column")
    (t--chrome-run! "previous-line")
    (check-equal! (t--chrome-point) 2 "up again, past the chrome line")
    (t--chrome-run! "next-line")
    (t--chrome-run! "next-line")
    (check-equal! (t--chrome-point) 14 "and down comes back")
    (buffer-kill! t--chrome-buf)))

(deftest 'chrome-never-touches-the-text
  "an attachment lives in the overlays; the bytes stay the bytes"
  (lambda ()
    (t--chrome! "body\n" 0)
    (overlay-set! t--chrome-buf 'chrome
      (list (chrome-after 4 "chip" "zz-badge")))
    (check-equal! (buffer-text t--chrome-buf) "body\n"
                  "the text holds no chrome")
    (check-equal! (buffer-size t--chrome-buf) 5
                  "and no byte was added")
    (buffer-kill! t--chrome-buf)))
