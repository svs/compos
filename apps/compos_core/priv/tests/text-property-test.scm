;;; text-property-test.scm --- the Emacs text property names, BUF first.

(domain! 'testing)
(effects! '(write))

(deftest 'text-properties-sit-on-the-text-and-move-with-it
  "put, get, the change positions, and a shift through an insert"
  (lambda ()
    (let ((buf (test-buffer! "zz-text-prop" "hello brave new world\n")))
      (put-text-property! buf 6 11 'face 'bold)
      (check-equal! (get-text-property buf 7 'face) 'bold "inside the span")
      (check-false! (get-text-property buf 11 'face) "past the span")
      (check-equal! (next-single-property-change buf 0 'face) 6 "the span starts")
      (check-equal! (next-single-property-change buf 6 'face) 11 "the span ends")
      (check-false! (next-single-property-change buf 11 'face) "no change after it")
      (check-equal! (next-single-property-change buf 11 'face 15) 15 "LIMIT when no change before it")
      (check-equal! (text-property-any buf 0 22 'face 'bold) 6 "the first bold position")
      (check-equal! (text-properties-at buf 8) '((face bold)) "every property at a position")
      (buffer-insert! buf 0 "oh ")
      (check-equal! (text-property-spans buf 'face) '((9 14 bold)) "the span moved with the text")
      (remove-text-properties! buf 0 30 '(face))
      (check-equal! (text-property-spans buf 'face) '() "removed")
      (buffer-kill! buf))))

(deftest 'a-sticky-property-grows-over-typed-text-and-a-nonsticky-one-does-not
  "a plain property is rear-sticky; one on the default nonsticky list is not; fontified is on it"
  (lambda ()
    (let ((buf (test-buffer! "zz-text-prop-sticky" "abcdef\n")))
      (check-true! (member 'fontified (text-property-default-nonsticky)) "fontified is nonsticky")
      (text-property-default-nonsticky! 'zz-ns #t)
      (put-text-property! buf 0 3 'face 'bold)
      (put-text-property! buf 0 3 'zz-ns #t)
      (buffer-insert! buf 3 "XY")
      (text-property-default-nonsticky! 'zz-ns #f)
      (check-equal! (text-property-spans buf 'face) '((0 5 bold)) "face grew over XY")
      (check-equal! (text-property-spans buf 'zz-ns) '((0 3 #t)) "zz-ns did not")
      (check-false! (member 'zz-ns (text-property-default-nonsticky)) "the list is as it was")
      (buffer-kill! buf))))
