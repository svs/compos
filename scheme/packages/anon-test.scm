;;; anon-test.scm --- anon-mode paints only the lines a window draws.
;;;
;;; The mode once painted whole buffers on every edit. A 400 KB chat took
;;; 1.4 s a paint, and the daemon hung. jit-lock now hands anon one range
;;; of drawn lines at a time. These tests hold that a paint touches only
;;; its range, and that one paint costs one sort.

(domain! 'testing)
(effects! '(write))

(deftest 'anon-redacted-drops-common-words-and-keeps-the-rest
  "a sort-merge against the common words, with no member per span"
  (lambda ()
    (let ((spans '((0 5 "Hello") (6 11 "Alice") (12 17 "Hello") (18 21 "Bob"))))
      (check-equal! (sort (anon--redacted spans '("Hello")))
                    '((6 11 "anon-redacted") (18 21 "anon-redacted"))
                    "every span of a common word goes, every other span stays")
      (check-equal! (length (anon--redacted spans '())) 4
                    "with no common words, every span is painted"))))

(deftest 'anon-fresh-names-each-unknown-word-once
  "a word in a cache or in an open question is not asked again"
  (lambda ()
    (let ((proper anon-proper-nouns) (common anon-common-words) (pending *anon-pending*))
      (set! anon-proper-nouns '("Alice"))
      (set! anon-common-words '("Hello"))
      (set! *anon-pending* '("Carol"))
      (let ((got (map caddr (anon--fresh '((0 5 "Hello") (6 11 "Alice") (12 15 "Bob")
                                           (16 19 "Bob") (20 25 "Carol"))))))
        (set! anon-proper-nouns proper)
        (set! anon-common-words common)
        (set! *anon-pending* pending)
        (check-equal! got '("Bob") "only Bob is new, and Bob is asked one time")))))

(deftest 'anon-fontify-paints-only-its-range
  "jit-lock gives anon one range; the lines outside it keep what they had"
  (lambda ()
    (let ((buf "*anon-test-range*")
          (pending *anon-pending*))
      (buffer-create buf)
      (buffer-insert! buf 0 "Zyxwqa one\nQwertyb two\n")
      ;; open questions, so the test sends nothing to decide
      (set! *anon-pending* (append '("Zyxwqa" "Qwertyb") *anon-pending*))
      (enable-minor-mode! buf "anon-local-mode")
      (jit-lock--fontify buf 0 11)
      (check-equal! (buffer-overlays buf "anon") '((0 6 "anon-redacted"))
                    "the first line is painted and the second is not")
      (jit-lock--fontify buf 11 23)
      (check-equal! (buffer-overlays buf "anon") '((0 6 "anon-redacted") (11 18 "anon-redacted"))
                    "the second range adds its bar and keeps the first")
      (jit-lock--fontify buf 11 23)
      (check-equal! (length (buffer-overlays buf "anon")) 2
                    "a range painted again replaces its own bars")
      (disable-minor-mode! buf "anon-local-mode")
      (check-equal! (buffer-overlays buf "anon") '() "the mode off takes every bar away")
      (set! *anon-pending* pending)
      (buffer-kill! buf))))
