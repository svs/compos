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
    (check-equal! (buffer-local-value 'mode-name t--sm-buf) "scratch-mode" "the default")
    (t--sm-done!)))

(deftest 'the-mode-a-user-chose-is-never-taken-back
  "M-x morg-mode in a scratch means plain morg, and it stays"
  (lambda ()
    (t--sm!)
    (with-current-buffer t--sm-buf (lambda () (set-mode! "morg-mode")))
    (scratch--set-mode! t--sm-buf)
    (check-equal! (buffer-local-value 'mode-name t--sm-buf) "morg-mode"
                  "plain morg survives the next scratch preparation")
    (t--sm-done!)))

(deftest 'scratch-mode-descends-from-morg-mode
  "one question answers for both, so a derived mode keeps morg's behavior"
  (lambda ()
    (check-true! (derived-mode? "scratch-mode" "morg-mode") "scratch is a morg")
    (check-false! (derived-mode? "morg-mode" "scratch-mode") "and not the other way")
    (check-false! (derived-mode? "text-mode" "morg-mode") "an unrelated mode is not")
    (t--sm!)
    (with-current-buffer t--sm-buf (lambda () (set-mode! "scratch-mode")))
    (check-true! (buffer-derived-mode? t--sm-buf "morg-mode")
                 "the buffer answers the same way, which is what preview and the paste hooks ask")
    (t--sm-done!)))

(deftest 'scratch-mode-runs-morgs-own-setup
  "it inherits the behavior instead of copying it"
  (lambda ()
    (t--sm!)
    (with-current-buffer t--sm-buf (lambda () (set-mode! "scratch-mode")))
    (check-true! (member "visual-line-mode" (buffer-local-value 'minor-modes t--sm-buf))
                 "morg's setup ran")
    (let ((keys (local-keys t--sm-buf)))
      (check-true! (member '("TAB" "morg-cycle") keys) "morg's folding key")
      (check-true! (member '("C-c C-n" "morg-next-heading") keys)
                   "and morg's motion keys"))
    (t--sm-done!)))

(deftest 'a-new-scratch-keeps-morgs-presentation
  "the legacy cleanup is for an old writing scratch, never a new one"
  (lambda ()
    (let* ((owner (test-buffer! "zz-scratch-owner" "text\n"))
           (scratch "*scratch:zz-scratch-owner-new*"))
      (when (buffer-known? scratch) (buffer-kill! scratch))
      (scratch--prepare! owner scratch)
      (check-equal! (buffer-local-value 'mode-name scratch) "scratch-mode" "the new scratch's mode")
      (check-true! (member "visual-line-mode" (buffer-local-value 'minor-modes scratch))
                   "morg's setup stays on")
      (buffer-kill! scratch)
      (buffer-kill! owner))))
