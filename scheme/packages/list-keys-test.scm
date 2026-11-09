;;; list-keys-test.scm --- a list mode's key table binds each key once.
;;;
;;; The table is installed in order and the last entry for a key wins,
;;; so a second entry is a silent override: dired's q was "dired-quit"
;;; and, three entries later, "quit-window" again.

(domain! 'testing)
(effects! '(read write))

(deftest 'no-list-mode-binds-one-key-twice
  "every 'keys table names each key once"
  (lambda ()
    (for-each
      (lambda (m)
        (let ((keys (map car (or (plist-get (cadr m) 'keys) '()))))
          (let loop ((ks keys) (seen '()))
            (unless (null? ks)
              (check-false! (member (car ks) seen)
                            (string-append (car m) " binds " (car ks) " twice"))
              (loop (cdr ks) (cons (car ks) seen))))))
      *list-modes*)))

(define-list-mode! "zz-keybar-mode"
  (list
    'buffer "*zz-keybar*"
    'rows (lambda (buf) (list "one" "two"))
    'key (lambda (buf row) row)
    'columns (lambda (buf) (list (list "name" #f)))
    'cells (lambda (buf row) (list row))
    'title (lambda (buf) "Keybar")
    'footer (lambda (buf) '(("q" "quit")))))

(deftest 'a-list-footer-is-the-keys-bar
  "a mode's footer names the main keys; the bar at the window's foot draws them"
  (lambda ()
    (list-mode-show! "zz-keybar-mode")
    (let ((buf "*zz-keybar*"))
      (let ((blocks (buffer-local-value 'footer-line-blocks buf)))
        (check-true! (pair? blocks) "the footer arrives as blocks")
        (check-equal! (plist-get (car blocks) 'tag) "c-keys-bar"
                      "and those blocks are the keys bar")))
    (buffer-kill! "*zz-keybar*")))

;; The standard keys bind SPC on every list's map after the mode's own
;; keys. Whatever they bind there must toggle: ibuffer once listed a
;; toggle under SPC in its keys and got a mark-only command on top of it.
(deftest 'the-standard-mark-key-toggles
  "the command the standard keys put on SPC marks a row, and clears it the second time"
  (lambda ()
    (list-mode-show! "zz-keybar-mode")
    (let* ((buf "*zz-keybar*")
           (cmd (cadr (assoc "SPC" (keymap-bindings (mode-keymap "zz-keybar-mode"))))))
      (with-current-buffer buf
        (lambda ()
          (list-goto-index! buf 0)
          (run-command cmd)
          (check-equal! (list-mark-of buf "one") "*" "the first press marks")
          (list-goto-index! buf 0)
          (run-command cmd)
          (check-equal! (list-mark-of buf "one") " " "the second press clears"))))
    (buffer-kill! "*zz-keybar*")))
