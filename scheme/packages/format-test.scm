;;; format-test.scm --- one test per format.

(domain! 'testing)
(effects! '(pure))

(deftest 'format-age-reads-as-a-short-age-or-an-ago
  "seconds become now, Ns, Nm, Nh, Nd; the ago style says just now and N ago; no time is an empty label"
  (lambda ()
    (check-equal! (format-age #f) "" "no time")
    (check-equal! (format-age 5) "now" "under ten seconds")
    (check-equal! (format-age 42) "42s" "seconds")
    (check-equal! (format-age 300) "5m" "minutes")
    (check-equal! (format-age 7200) "2h" "hours")
    (check-equal! (format-age 200000) "2d" "days")
    (check-equal! (format-age -30) "now" "a time ahead of the clock is now")
    (check-equal! (format-age #f 'ago) "" "no time, no label")
    (check-equal! (format-age 0 'ago) "just now" "now")
    (check-equal! (format-age 42 'ago) "just now" "and under a minute")
    (check-equal! (format-age 300 'ago) "5m ago" "minutes ago")
    (check-equal! (format-age 7200 'ago) "2h ago" "hours ago")
    (check-equal! (format-age 172800 'ago) "2d ago" "days ago")))

(deftest 'format-bytes-reads-in-the-units-the-reader-knows
  "si, iec and short units; whole units or one decimal; a sign for a change; no number, no label"
  (lambda ()
    (check-equal! (format-bytes 512) "512 B" "bytes")
    (check-equal! (format-bytes 8192) "8 KB" "whole kilobytes")
    (check-equal! (format-bytes 1048576) "1 MB" "whole megabytes")
    (check-equal! (format-bytes 4661224676 'si 1) "4.3 GB" "gigabytes with one decimal")
    (check-equal! (format-bytes 268435456 'si 1) "256.0 MB" "an exact size keeps its decimal")
    (check-equal! (format-bytes 512 'iec) "512 B" "bytes are bytes in every style")
    (check-equal! (format-bytes 2048 'iec) "2 KiB" "kibibytes")
    (check-equal! (format-bytes (* 3 1048576) 'iec 1) "3.0 MiB" "mebibytes with one decimal")
    (check-equal! (format-bytes 1610612736 'iec 1) "1.5 GiB" "gibibytes with one decimal")
    (check-equal! (format-bytes 512 'short 1) "512" "short units say nothing for bytes")
    (check-equal! (format-bytes 5000 'short 1) "4.9k" "and write kilobytes the way dired does")
    (check-equal! (format-bytes 1468006 'short 1) "1.4M" "megabytes too")
    (check-equal! (format-bytes 512 'si 0 #t) "+512 B" "a gain of bytes")
    (check-equal! (format-bytes 262144 'si 1 #t) "+256.0 KB" "a gain of kilobytes")
    (check-equal! (format-bytes (- 0 3145728) 'si 1 #t) "-3.0 MB" "a loss says so")
    (check-equal! (format-bytes #f) "" "no size, no label")))

(deftest 'format-percent-is-whole-and-never-divides-by-nothing
  "a part of a whole as a whole-number percent, with and without the sign"
  (lambda ()
    (check-equal! (percent-of 1 3) 33 "rounds down")
    (check-equal! (percent-of 3 3) 100 "all of it")
    (check-equal! (percent-of 5 0) 0 "nothing to divide by")
    (check-equal! (percent-of #f 10) 0 "no part")
    (check-equal! (format-percent 1 4) "25%" "with the sign")
    (check-equal! (format-percent 0 0) "0%" "an empty whole")))

(deftest 'format-elide-keeps-the-ends-or-the-head
  "a string over its width loses its middle, or its end, to one ellipsis"
  (lambda ()
    (check-equal! (format-elide "abcdef" 10) "abcdef" "under the width, as it is")
    (check-equal! (format-elide "abcdef" 6) "abcdef" "at the width too")
    (check-equal! (format-elide "0123456789abcdefghijklmnopqrstuvwxyz" 21)
                  "0123456789…qrstuvwxyz" "the middle goes, ten each side")
    (check-equal! (format-elide "abcdefghijkl" 8) "abcd…jkl" "an even width keeps one more at the head")
    (check-equal! (format-elide "abcdefghijkl" 7 'end) "abcdef…" "the end goes")
    (check-equal! (format-elide "abcdefghijkl" 1) "a" "a width of one has no room for an ellipsis")))
