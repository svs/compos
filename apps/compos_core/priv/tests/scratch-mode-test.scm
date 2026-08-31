;;; scratch-mode-test.scm --- the scratch's mode, and what derives from what.
;;;
;;; scratch-mode is morg-mode with a scratch's habits. The mode a buffer is
;;; in belongs to the user, so the only mode this code sets is the one a new
;;; scratch starts in.

(domain! 'testing)
(effects! '(write))

(define t--sm-buf "zz-scratch-mode")

(define (t--sm! ) (test-buffer! t--sm-buf "") t--sm-buf)

(define (t--sm-done!) (when (buffer-known? t--sm-buf) (buffer-kill! t--sm-buf)))

(deftest 'a-new-scratch-starts-in-scratch-mode
  "the mode is the default, not a rule"
  (lambda ()
    (t--sm!)
    (buffer-set-local! t--sm-buf 'mode-name #f)
    (scratch--set-mode! t--sm-buf)
    (check-equal! (buffer-local t--sm-buf 'mode-name) "scratch-mode" "the default")
    (t--sm-done!)))

(deftest 'the-mode-a-user-chose-is-never-taken-back
  "M-x morg-mode in a scratch means plain morg, and it stays"
  (lambda ()
    (t--sm!)
    (with-current-buffer t--sm-buf (lambda () (set-mode! "morg-mode")))
    (scratch--set-mode! t--sm-buf)
    (check-equal! (buffer-local t--sm-buf 'mode-name) "morg-mode"
                  "plain morg survives the next scratch preparation")
    (t--sm-done!)))

(deftest 'scratch-mode-descends-from-morg-mode
  "one question answers for both, so a derived mode keeps morg's behavior"
  (lambda ()
    (check-true! (mode-is? "scratch-mode" "morg-mode") "scratch is a morg")
    (check-false! (mode-is? "morg-mode" "scratch-mode") "and not the other way")
    (check-false! (mode-is? "text-mode" "morg-mode") "an unrelated mode is not")
    (t--sm!)
    (with-current-buffer t--sm-buf (lambda () (set-mode! "scratch-mode")))
    (check-true! (buffer-mode-is? t--sm-buf "morg-mode")
                 "the buffer answers the same way, which is what preview and the paste hooks ask")
    (t--sm-done!)))

(deftest 'scratch-mode-runs-morgs-own-setup
  "it inherits the behavior instead of copying it"
  (lambda ()
    (t--sm!)
    (with-current-buffer t--sm-buf (lambda () (set-mode! "scratch-mode")))
    (check-true! (member "writing-mode" (buffer-local t--sm-buf 'minor-modes))
                 "morg's setup ran")
    (let ((keys (local-keys t--sm-buf)))
      (check-true! (member '("TAB" "morg-cycle") keys) "morg's folding key")
      (check-true! (member '("C-c C-n" "morg-next-heading") keys)
                   "and morg's motion keys"))
    (t--sm-done!)))
