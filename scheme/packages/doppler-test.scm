;;; doppler-test.scm --- Doppler index value previews.

(deftest 'doppler-index-elides-the-middle-of-long-values
  "the preview keeps up to ten characters at each end"
  (lambda ()
    (check-equal! (doppler--elide-value "0123456789abcdefghijklmnopqrstuvwxyz")
                  "0123456789…qrstuvwxyz" "a long value shows ten characters each side")
    (check-equal! (doppler--elide-value "abcd123456789wxyz")
                  "abcd12…89wxyz" "a shorter value shows fewer, and the middle stays hidden")))

(deftest 'doppler-index-hides-short-and-missing-values
  "a preview never reveals a complete short secret"
  (lambda ()
    (check-equal! (doppler--elide-value "short-value")
                  "••••" "a short value stays hidden")
    (check-equal! (doppler--elide-value "0123456789abc")
                  "0123…9abc" "four each side is the smallest preview")
    (check-equal! (doppler--elide-value #f)
                  "••••" "a missing value stays hidden")))

;; A value with a line break drew its row on two lines, and every row below
;; it was off by one: the arrow keys moved to the wrong row.
(deftest 'an-elided-value-is-one-line
  "a secret value with line breaks elides to a single line"
  (lambda ()
    (let ((shown (doppler--elide-value "abcdefghij\nklmnop\r\nqrstuvwxyz0123")))
      (check-false! (string-contains? shown "\n") "no line feed")
      (check-false! (string-contains? shown "\r") "no carriage return"))))
