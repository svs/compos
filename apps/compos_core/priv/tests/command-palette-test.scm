;;; command-palette-test.scm --- the palette's natural-language bind intent.
;;;
;;; A bind sentence is policy, so it lives here; the palette's key
;;; presses and debounce wait stay in ExUnit.

(domain! 'testing)
(effects! '(read))

;; a dummy target, so no test names a production command
(define-command "zz-palette-bind" "Test: a palette bind target"
  (lambda () #t))

(deftest 'a-bind-sentence-parses-into-a-key-and-a-command
  "the palette reads \"bind C-x C-g k to group-kill\" as its two parts"
  (lambda ()
    (check-equal! (command-palette--bind-parse "bind <f9> z to zz-palette-bind")
                  '("<f9> z" "zz-palette-bind")
                  "keys then command")
    (check-equal! (command-palette--bind-parse "Bind <f9> z to zz-palette-bind")
                  '("<f9> z" "zz-palette-bind")
                  "the verb is case-insensitive")
    (check-false! (command-palette--bind-parse "bind <f9> z zz-palette-bind")
                  "a missing \"to\" does not parse")
    (check-false! (command-palette--bind-parse "bind to zz-palette-bind")
                  "no keys does not parse")
    (check-false! (command-palette--bind-parse "bind <f9> z to no-such-command-zz")
                  "a command that does not exist does not parse")
    (check-false! (command-palette--bind-parse "save-buffer")
                  "a plain command name is not a bind sentence")))

(deftest 'a-bind-sentence-is-the-first-palette-candidate
  "the intent candidate leads the palette results"
  (lambda ()
    (let ((cands (command-palette-candidates "bind <f9> z to zz-palette-bind")))
      (check-true! (pair? cands) "there is at least one candidate")
      (check-equal! (car (car cands)) "bind <f9> z to zz-palette-bind"
                    "the first candidate names the bind sentence"))))

