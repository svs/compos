;;; buffer-search-test.scm --- what buffer-search counts as a match.
;;;
;;; The buffer stores text; Scheme decides what a match is. FOLD makes
;;; case not count, Unicode included. Backward answers the last match that
;;; starts before FROM, counted left to right without overlap.

(domain! 'testing)
(effects! '(write))

(define t--bsearch-buf "*zz-bsearch*")

(define (t--bsearch text thunk)
  (when (buffer-known? t--bsearch-buf) (buffer-kill! t--bsearch-buf))
  (buffer-create t--bsearch-buf)
  (buffer-append! t--bsearch-buf text)
  (let ((r (with-current-buffer t--bsearch-buf thunk)))
    (buffer-kill! t--bsearch-buf)
    r))

(deftest 'buffer-search-finds-forward-and-backward-with-and-without-case
  "byte ranges forward and backward, exact and folded"
  (lambda ()
    (check-equal!
      (t--bsearch "one two one Two\n\n\nend"
        (lambda ()
          (list (buffer-search "one" 0)
                (buffer-search "one" 1)
                (buffer-search "Two" 0)
                (buffer-search "two" 5)
                (buffer-search "two" 5 #t)
                (buffer-search-backward "one" 8)
                (buffer-search-backward "one" 9)
                (buffer-search-backward "TWO" 21 #t)
                (buffer-search-backward "TWO" 12 #t)
                (buffer-search-backward "TWO" 21))))
      '((0 3) (8 11) (12 15) #f (12 15) (0 3) (8 11) (12 15) (4 7) #f)
      "the ranges")))

(deftest 'buffer-search-backward-counts-matches-without-overlap
  "three newlines hold one blank-line match, at the first newline"
  (lambda ()
    (check-equal!
      (t--bsearch "ab\n\n\ncd"
        (lambda ()
          (list (buffer-search-backward "\n\n" 7)
                (buffer-search-backward "\n\n" 3)
                (buffer-search-backward "\n\n" 2))))
      '((2 4) (2 4) #f)
      "a match that overlaps the one before it does not count")))

(deftest 'buffer-search-edges-and-unicode-case
  "FROM at the end finds nothing; folded case knows Unicode"
  (lambda ()
    (check-equal!
      (t--bsearch "aÜnïb [x]"
        (lambda ()
          (list (buffer-search "b" 7)
                (buffer-search "b" 8)
                (buffer-search "ünÏ" 0 #t)
                (buffer-search "ünÏ" 0)
                (buffer-search "[X]" 0 #t)
                (buffer-search-backward "üN" 7 #t)
                (buffer-search "zz" 0))))
      '(#f #f (1 6) #f (8 11) (1 4) #f)
      "edges, Unicode case, and regexp characters taken literally")))

(deftest 'buffer-search-on-a-buffer-larger-than-its-window
  "a large buffer gives the same answers as a small one"
  (lambda ()
    ;; T is where the last line starts, after 240 KB of filler lines
    (let* ((filler (string-repeat "lorem ipsum\n" 20000))
           (t (+ 7 (string-byte-length filler))))
      (check-equal!
        (t--bsearch (string-append "Needle\n" filler "aa aaa NEEDLE")
          (lambda ()
            (list (buffer-search "NEEDLE" 1 #t)
                  (buffer-search-backward "needle" (+ t 7) #t)
                  (buffer-search-backward "LOREM" t #t)
                  (buffer-search-backward "aa" (+ t 13)))))
        (list (list (+ t 7) (+ t 13)) '(0 6) (list (- t 12) (- t 7)) (list (+ t 3) (+ t 5)))
        "far matches forward and backward, folded, without overlap"))))
