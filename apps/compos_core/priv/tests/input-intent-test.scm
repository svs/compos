;;; input-intent-test.scm --- what a ranged input intent means.
;;;
;;; The browser reports an intent as a type, a byte range, and text. The
;;; key path takes a collapsed intent; a ranged one comes to input-intent!,
;;; which is policy and therefore tested here.

(domain! 'testing)
(effects! '(write))

(define t--intent-buf "*intent-test*")

(define (t--intent-fresh! text)
  (test-buffer! t--intent-buf text)
  t--intent-buf)

(define (t--intent! type from to text)
  (with-current-buffer t--intent-buf
    (lambda () (input-intent! type from to text))))

(deftest 'a-ranged-insert-replaces-the-range-and-leaves-point-after-it
  "the range goes, the text lands where the range began, no mark remains"
  (lambda ()
    (t--intent-fresh! "hello world")
    (t--intent! "insertText" 6 11 "there")
    (check-equal! (buffer-text t--intent-buf) "hello there" "the word is replaced")
    (check-equal! (with-current-buffer t--intent-buf (lambda () (point))) 11
                  "point stands after the inserted text")
    (check-false! (with-current-buffer t--intent-buf (lambda () (mark))) "no mark is left")))

(deftest 'a-ranged-delete-of-any-kind-removes-the-range
  "deleteWordBackward, deleteByCut and the rest all mean the same range"
  (lambda ()
    (t--intent-fresh! "hello world")
    (t--intent! "deleteWordBackward" 5 11 "")
    (check-equal! (buffer-text t--intent-buf) "hello" "the range is gone")
    (t--intent! "deleteByCut" 0 2 "")
    (check-equal! (buffer-text t--intent-buf) "llo" "a cut is a delete")))

(deftest 'a-paragraph-intent-over-a-range-is-a-newline
  "insertParagraph replaces the range with one newline"
  (lambda ()
    (t--intent-fresh! "ab cd")
    (t--intent! "insertParagraph" 2 3 "")
    (check-equal! (buffer-text t--intent-buf) "ab\ncd" "the space became a newline")))

(deftest 'a-registered-handler-takes-its-intent-first
  "a mode owns formatBold; the default path never sees it"
  (lambda ()
    (t--intent-fresh! "abc")
    (let ((seen '()))
      (on-input-intent! "formatBold"
        (lambda (from to text) (set! seen (list from to)) #t))
      (t--intent! "formatBold" 0 3 "")
      (check-equal! seen '(0 3) "the handler saw the range")
      (check-equal! (buffer-text t--intent-buf) "abc" "the text is untouched")
      (on-input-intent! "formatBold" (lambda (from to text) #f)))))

(deftest 'an-unknown-intent-changes-nothing
  "the default path refuses what it does not know"
  (lambda ()
    (t--intent-fresh! "abc")
    (check-false! (t--intent! "insertHorizontalRule" 0 3 "") "refused")
    (check-equal! (buffer-text t--intent-buf) "abc" "the text is untouched")))
