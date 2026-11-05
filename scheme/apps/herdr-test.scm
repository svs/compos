;;; herdr-test.scm --- the herdr listing says the state of each agent.

(require 'herdr)

(domain! 'testing)
(effects! '(pure))

(define (t--herdr-row state)
  (list 'shell "zz-shell" 'agent "claude" 'model "" 'state state 'kind "" 'msg ""))

(deftest 'a-working-agent-has-a-turning-glyph
  "a working row's glyph carries the spinner face over its colour; other states do not turn"
  (lambda ()
    (let ((faces (lambda (state)
                   (list-cell-face (car (herdr--cells "zz-herdr" (t--herdr-row state)))))))
      (check-true! (member "spinner" (map (lambda (s) (nth 2 s)) (faces "working")))
                   "the working glyph turns")
      (check-true! (member "chat-live" (map (lambda (s) (nth 2 s)) (faces "working")))
                   "and keeps the working colour")
      (check-equal! (faces "idle") "chat-idle" "an idle glyph stays still"))))

(deftest 'a-narrow-herdr-listing-keeps-the-state
  "when the columns do not fit, the model column hides before the state column"
  (lambda ()
    (let* ((cols (herdr--narrow-columns "zz-herdr"))
           (shown (map car (filter (lambda (c) (not (list-col-hidden? c)))
                                   (list-drop-columns cols 50)))))
      (check-true! (member "state" shown) "the state stays")
      (check-false! (member "model" shown) "the model goes"))))
