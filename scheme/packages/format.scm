;;; format.scm --- ages, byte sizes, percentages and elided strings, one way.
;;;
;;; Six packages wrote these labels each in its own words: ibuffer, web,
;;; perf, profile, models and doppler. This is the one place. A package
;;; keeps its own policy (what it counts, what it hides, which unit names
;;; its readers know) and asks here for the text.
;;;
;;;   (format-age SECONDS [STYLE])              "now", "42s", "5m", "2h", "3d"
;;;   (format-bytes N [UNITS DECIMALS SIGNED?]) "512 B", "1.5 GiB", "4.9k"
;;;   (percent-of PART WHOLE)                   42
;;;   (format-percent PART WHOLE)               "42%"
;;;   (format-elide S WIDTH [STYLE])            "0123456789…qrstuvwxyz"
;;;
;;; Every number is integer arithmetic: no float ever reaches a label.

(domain! 'ui)
(effects! '(pure))

;;; --- ages ---------------------------------------------------------------------

;; the count and the unit letter of an age in seconds
(define (format--age-parts age)
  (cond ((< age 60) (list age "s"))
        ((< age 3600) (list (quotient age 60) "m"))
        ((< age 86400) (list (quotient age 3600) "h"))
        (else (list (quotient age 86400) "d"))))

;; SECONDS is an age, not a time; #f gives "" and a negative age is now.
;; The short style (the default) says "now" under ten seconds, then
;; "42s", "5m", "2h", "3d". The 'ago style says "just now" under a
;; minute, then "5m ago", "2h ago", "3d ago".
(define (format-age seconds &optional style)
  (if (not (number? seconds))
      ""
      (let* ((age (max 0 seconds))
             (parts (format--age-parts age))
             (text (string-append (number->string (car parts)) (cadr parts))))
        (cond ((equal? style 'ago)
               (if (< age 60) "just now" (string-append text " ago")))
              ((< age 10) "now")
              (else text)))))

;;; --- byte sizes ---------------------------------------------------------------

;; N/UNIT as "W.T", rounded to the nearest tenth
(define (format--tenths n unit)
  (let* ((tenths (quotient (+ (* n 10) (quotient unit 2)) unit))
         (whole (quotient tenths 10))
         (tenth (remainder tenths 10)))
    (string-append (number->string whole) "." (number->string tenth))))

;; the unit labels of a style, bytes first
(define (format--byte-labels units)
  (cond ((equal? units 'iec) '(" B" " KiB" " MiB" " GiB"))
        ((equal? units 'short) '("" "k" "M" "G"))
        (else '(" B" " KB" " MB" " GB"))))

;; N bytes as a label. UNITS is 'si ("KB", the default), 'iec ("KiB") or
;; 'short ("k", the way dired writes a size). DECIMALS 1 shows a tenth
;; above bytes; the default 0 shows the whole unit. SIGNED? writes a +
;; or - for a change in size. A non-number gives "".
(define (format-bytes n &optional units decimals signed?)
  (if (not (number? n))
      ""
      (let* ((labels (format--byte-labels units))
             (a (if (< n 0) (- 0 n) n))
             (step (cond ((>= a 1073741824) 3)
                         ((>= a 1048576) 2)
                         ((>= a 1024) 1)
                         (else 0)))
             (unit (list-ref '(1 1024 1048576 1073741824) step))
             (digits (cond ((= step 0) (number->string a))
                           ((equal? decimals 1) (format--tenths a unit))
                           (else (number->string (quotient a unit)))))
             (sign (cond ((not signed?) "")
                         ((< n 0) "-")
                         (else "+"))))
        (string-append sign digits (list-ref labels step)))))

;;; --- percentages --------------------------------------------------------------

;; PART of WHOLE as a whole-number percent; 0 when WHOLE is nothing
(define (percent-of part whole)
  (if (and (number? part) (number? whole) (> whole 0))
      (quotient (* 100 part) whole)
      0))

(define (format-percent part whole)
  (string-append (number->string (percent-of part whole)) "%"))

;;; --- elided strings -----------------------------------------------------------

;; S cut to WIDTH characters with one ellipsis. The 'middle style (the
;; default) keeps both ends, the head one longer when WIDTH is even;
;; 'end keeps the head. Under WIDTH, S stays as it is.
(define (format-elide s width &optional style)
  (let ((n (string-length s)))
    (cond ((<= n width) s)
          ((<= width 1) (substring s 0 width))
          ((equal? style 'end) (string-append (substring s 0 (- width 1)) "…"))
          (else
           (let* ((keep (- width 1))
                  (head (quotient (+ keep 1) 2))
                  (tail (- keep head)))
             (string-append (substring s 0 head) "…" (substring s (- n tail) n)))))))

(public! 'format-age "(format-age SECONDS [STYLE]) — an age as \"now\", \"42s\", \"5m\", \"2h\", \"3d\"; STYLE 'ago says \"just now\", \"5m ago\"; #f gives \"\"")
(public! 'format-bytes "(format-bytes N [UNITS DECIMALS SIGNED?]) — N bytes as \"512 B\", \"1.5 GiB\", \"4.9k\"; UNITS 'si 'iec or 'short, DECIMALS 0 or 1, SIGNED? writes + or -")
(public! 'percent-of "(percent-of PART WHOLE) — PART of WHOLE as a whole-number percent; 0 when WHOLE is nothing")
(public! 'format-percent "(format-percent PART WHOLE) — (percent-of PART WHOLE) with a % sign")
(public! 'format-elide "(format-elide S WIDTH [STYLE]) — S cut to WIDTH characters with one ellipsis; STYLE 'middle keeps both ends, 'end keeps the head")
