;;; buffer-local-test.scm --- buffer-local takes a buffer name or a buffer ref.
;;;
;;; A Buffer.Ref is the immutable identity of a buffer, so it names the
;;; buffer as well as its name does. A symbol in the BUF place is a call
;;; with the arguments swapped, and buffer-local refuses it.

(domain! 'testing)
(effects! '(write))

(define *t--bl-buf* "*zz-buffer-local*")

(deftest 'buffer-local-reads-by-name-and-by-ref
  "a ref and a name read the same local"
  (lambda ()
    (unless (buffer-known? *t--bl-buf*) (buffer-create *t--bl-buf*))
    (buffer-set-local! *t--bl-buf* 'zz-color "blue")
    (check-equal! (buffer-local *t--bl-buf* 'zz-color) "blue" "the name reads the local")
    (check-equal! (buffer-local (buffer-ref *t--bl-buf*) 'zz-color) "blue" "the ref reads the local")
    (check-false! (ignore-errors (lambda () (buffer-local 'zz-color *t--bl-buf*) #t))
                  "a symbol in the BUF place raises")
    (buffer-kill! *t--bl-buf*)))
