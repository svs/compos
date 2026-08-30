;;; list-keys-test.scm --- a list mode's key table binds each key once.
;;;
;;; The table is installed in order and the last entry for a key wins,
;;; so a second entry is a silent override: dired's q was "dired-quit"
;;; and, three entries later, "quit-window" again.

(domain! 'testing)
(effects! '(read))

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
