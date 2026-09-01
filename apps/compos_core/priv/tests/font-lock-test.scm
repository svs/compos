;;; font-lock-test.scm --- keywords paint, derived modes inherit, isearch paints.

(domain! 'testing)
(effects! '(write))

(define-mode "zz-fl-parent" (lambda () #t))
(define-derived-mode "zz-fl-child" "zz-fl-parent" (lambda () #t))
(font-lock-set-keywords! "zz-fl-parent" '(("TODO" "warn")))
(font-lock-set-keywords! "zz-fl-child" '(("[0-9]+" "ts-number")))

(define (fl-test-overlays buf tag)
  (filter (lambda (o) (member (caddr o) '("warn" "ts-number" "isearch" "lazy-highlight")))
          (buffer-overlays buf)))

(deftest 'keywords-paint-every-match-and-a-derived-mode-inherits
  "the parent's TODO and the child's numbers, both in the child's buffer"
  (lambda ()
    (let ((buf (test-buffer! "zz-fl-buf" "TODO 12 and 3\n")))
      (with-current-buffer buf (lambda () (set-mode! "zz-fl-child")))
      (check-equal! (font-lock-keywords "zz-fl-child") '(("TODO" "warn") ("[0-9]+" "ts-number"))
                    "the parent's keywords come first")
      (let ((ov (fl-test-overlays buf 'font-lock)))
        (check-true! (member '(0 4 "warn") ov) "TODO wears warn")
        (check-true! (member '(5 7 "ts-number") ov) "12 wears ts-number")
        (check-true! (member '(12 13 "ts-number") ov) "and 3"))
      (font-lock-disable! buf)
      (check-equal! (fl-test-overlays buf 'font-lock) '() "disable clears the paint")
      (buffer-kill! buf))))

(deftest 'isearch-paints-the-current-match-and-the-others
  "isearch--paint! puts isearch on the match and lazy-highlight on the rest"
  (lambda ()
    (let ((buf (test-buffer! "zz-fl-buf" "ab ab ab\n")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (check-equal! (isearch-matches "ab") '((0 2) (3 5) (6 8)) "three matches")
      (isearch--paint! "ab" '(3 5))
      (let ((ov (fl-test-overlays buf 'isearch)))
        (check-true! (member '(3 5 "isearch") ov) "the current match")
        (check-true! (member '(0 2 "lazy-highlight") ov) "the one before")
        (check-true! (member '(6 8 "lazy-highlight") ov) "the one after"))
      (isearch--unpaint!)
      (check-equal! (fl-test-overlays buf 'isearch) '() "cleared")
      (buffer-kill! buf))))

(deftest 'hl-line-mode-turns-the-line-highlight-off-and-on
  "the local says off, then on"
  (lambda ()
    (let ((buf (test-buffer! "zz-fl-buf" "x\n")))
      (check-true! (hl-line-on? buf) "on by default")
      (with-current-buffer buf (lambda () (run-command "hl-line-mode")))
      (check-false! (hl-line-on? buf) "off")
      (with-current-buffer buf (lambda () (run-command "hl-line-mode")))
      (check-true! (hl-line-on? buf) "on again")
      (buffer-kill! buf))))
