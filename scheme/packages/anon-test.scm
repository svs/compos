;;; anon-test.scm --- anon-mode paints only the lines a window draws.
;;;
;;; The mode once painted whole buffers on every edit. A 400 KB chat took
;;; 1.4 s a paint, and the daemon hung. jit-lock now hands anon one range
;;; of drawn lines at a time. These tests hold that a paint touches only
;;; its range, and that one paint sorts only its own spans.

(domain! 'testing)
(effects! '(write))

(deftest 'anon-redacted-drops-common-words-and-keeps-the-rest
  "a span of a common word goes; the cache size does not set the cost"
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

(deftest 'anon-lru-puts-used-words-first-and-cuts-the-rest
  "a used word goes to the front; a cache keeps anon-cache-size words"
  (lambda ()
    (let ((size anon-cache-size))
      (set! anon-cache-size 3)
      (let ((got (anon--lru '("a" "b" "c" "d" "e") '("e" "zz"))))
        (set! anon-cache-size size)
        (check-equal! got '("e" "a" "b")
                      "e moves to the front, zz is not cached, d and e's old place drop")))))

(deftest 'anon-fresh-touches-the-cached-words-it-meets
  "a cache hit is noted for the next prune; a pending word is not"
  (lambda ()
    (let ((proper anon-proper-nouns) (common anon-common-words)
          (pending *anon-pending*) (touched *anon-touched*))
      (set! anon-proper-nouns '("Alice"))
      (set! anon-common-words '("Hello"))
      (set! *anon-pending* '("Carol"))
      (set! *anon-touched* '())
      (anon--fresh '((0 5 "Hello") (6 11 "Alice") (12 17 "Carol")))
      (let ((got (sort *anon-touched*)))
        (set! anon-proper-nouns proper)
        (set! anon-common-words common)
        (set! *anon-pending* pending)
        (set! *anon-touched* touched)
        (check-equal! got '("Alice" "Hello") "both cache hits are noted")))))

(deftest 'anon-bars-the-name-the-title-painter-draws
  "while anon-mode is on, buffer-modeline-name bars the words of the name"
  (lambda ()
    (let ((global *anon-global*) (common anon-common-words) (buf "*zz-anon Zelda Quux*"))
      (buffer-create buf)
      (set! anon-common-words '())
      (set! *anon-global* #t)
      (anon--advise!)
      (let ((on (buffer-modeline-name buf)))
        (set! *anon-global* #f)
        (let ((off (buffer-modeline-name buf)))
          (set! *anon-global* global)
          (set! anon-common-words common)
          (unless global (anon--unadvise!))
          (buffer-kill! buf)
          (check-equal! (string-contains? on "Zelda") #f "the name is barred while anon-mode is on")
          (check-equal! off buf "the name is whole while anon-mode is off"))))))
