;;; doppler-test.scm --- Doppler index value previews.

(deftest 'doppler-index-elides-the-middle-of-long-values
  "the preview keeps four characters at each end"
  (lambda ()
    (check-equal! (doppler--elide-value "abcd123456789wxyz")
                  "abcd…wxyz" "the middle stays hidden")))

(deftest 'doppler-index-hides-short-and-missing-values
  "a preview never reveals a complete short secret"
  (lambda ()
    (check-equal! (doppler--elide-value "short-value")
                  "••••" "a short value stays hidden")
    (check-equal! (doppler--elide-value #f)
                  "••••" "a missing value stays hidden")))
