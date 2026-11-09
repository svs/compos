;;; buffer-local-test.scm --- buffer-local-value, the one accessor of a buffer-local.
;;;
;;; buffer-local-value takes the variable first, as in Emacs. BUF is a
;;; buffer name or a buffer ref; #f holds no locals. The default stands in
;;; only for a defvar-local variable, so a function that shares the name
;;; of a local is never the answer. The primitive buffer-local is the
;;; same read in the old order, and it refuses a symbol in the BUF place.

(domain! 'testing)
(effects! '(write))

(define *t--bl-buf* "*zz-buffer-local*")
(define (t--bl-fresh!)
  (unless (buffer-known? *t--bl-buf*) (buffer-create *t--bl-buf*))
  *t--bl-buf*)

(deftest 'buffer-local-value-reads-by-name-and-by-ref
  "a ref and a name read the same local"
  (lambda ()
    (let ((b (t--bl-fresh!)))
      (buffer-set-local! b 'zz-color "blue")
      (check-equal! (buffer-local-value 'zz-color b) "blue" "the name reads the local")
      (check-equal! (buffer-local-value 'zz-color (buffer-ref b)) "blue" "the ref reads the local")
      (check-equal! (buffer-local-value b 'zz-color) "blue" "the old order gets the same answer")
      (check-false! (buffer-local-value 'zz-color #f) "#f is no buffer and has no locals")
      (buffer-kill! b))))

(define (t--bl-function-named-like-a-local b) b)
(defvar-local 't--bl-auto "the default")

(deftest 'buffer-local-value-defaults-only-for-a-defvar-local
  "a defvar-local reads its default; a function name is no default"
  (lambda ()
    (let ((b (t--bl-fresh!)))
      (check-false! (buffer-local-value 't--bl-function-named-like-a-local b)
                    "a function that shares the name is not the value")
      (check-equal! (buffer-local-value 't--bl-auto b) "the default" "no own value: the default")
      (buffer-set-local! b 't--bl-auto "own")
      (check-equal! (buffer-local-value 't--bl-auto b) "own" "the own value wins")
      (buffer-kill! b))))

(deftest 'buffer-local-refuses-a-symbol-as-buf
  "the old order: a symbol in the BUF place raises, #f answers #f"
  (lambda ()
    (let ((b (t--bl-fresh!)))
      (check-false! (buffer-local #f 'zz-color) "#f is no buffer")
      (check-false! (ignore-errors (lambda () (buffer-local 'zz-color b) #t))
                    "a symbol in the BUF place raises")
      (buffer-kill! b))))
