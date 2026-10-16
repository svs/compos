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
    (with-stubs (list (list 'anon-proper-nouns '("Alice"))
                      (list 'anon-common-words '("Hello"))
                      (list '*anon-pending* '("Carol")))
      (lambda ()
        (check-equal! (map caddr (anon--fresh '((0 5 "Hello") (6 11 "Alice") (12 15 "Bob")
                                                (16 19 "Bob") (20 25 "Carol"))))
                      '("Bob") "only Bob is new, and Bob is asked one time")))))

(deftest 'anon-fontify-paints-only-its-range
  "jit-lock gives anon one range; the lines outside it keep what they had"
  (lambda ()
    (let ((buf "*anon-test-range*"))
      (buffer-create buf)
      (buffer-insert! buf 0 "Zyxwqa one\nQwertyb two\n")
      ;; open questions, so the test sends nothing to decide
      (with-stub '*anon-pending* (append '("Zyxwqa" "Qwertyb") *anon-pending*)
        (lambda ()
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
          (check-equal! (buffer-overlays buf "anon") '() "the mode off takes every bar away")))
      (buffer-kill! buf))))

(deftest 'anon-lru-puts-used-words-first-and-cuts-the-rest
  "a used word goes to the front; a cache keeps anon-cache-size words"
  (lambda ()
    (check-equal! (with-stub 'anon-cache-size 3
                    (lambda () (anon--lru '("a" "b" "c" "d" "e") '("e" "zz"))))
                  '("e" "a" "b")
                  "e moves to the front, zz is not cached, d and e's old place drop")))

(deftest 'anon-fresh-touches-the-cached-words-it-meets
  "a cache hit is noted for the next prune; a pending word is not"
  (lambda ()
    (check-equal!
      (with-stubs (list (list 'anon-proper-nouns '("Alice"))
                        (list 'anon-common-words '("Hello"))
                        (list '*anon-pending* '("Carol"))
                        (list '*anon-touched* '()))
        (lambda ()
          (anon--fresh '((0 5 "Hello") (6 11 "Alice") (12 17 "Carol")))
          (sort *anon-touched*)))
      '("Alice" "Hello") "both cache hits are noted")))

(deftest 'anon-bars-the-name-the-title-painter-draws
  "while anon-mode is on, buffer-modeline-name bars the words of the name"
  (lambda ()
    (let ((global *anon-global*) (buf "*zz-anon Zelda Quux*"))
      (buffer-create buf)
      (with-stubs (list (list 'anon-common-words '()) (list '*anon-global* #t))
        (lambda ()
          (anon--advise!)
          (let ((on (buffer-modeline-name buf)))
            (set! *anon-global* #f)
            (let ((off (buffer-modeline-name buf)))
              (check-equal! (string-contains? on "Zelda") #f "the name is barred while anon-mode is on")
              (check-equal! off buf "the name is whole while anon-mode is off")))))
      (unless global (anon--unadvise!))
      (buffer-kill! buf))))

(deftest 'anon-redacts-a-view-only-while-a-window-shows-it
  "a hidden buffer's view passes as its mode wrote it; showing the buffer bars it"
  (lambda ()
    (let ((buf "*zz-anon-view*")
          (tree '(div "Zelda Quux met here")))
      (buffer-create buf)
      (with-stub 'anon-common-words '()
        (lambda ()
          (buffer-set-local! buf 'render-mode "blocks")
          (enable-minor-mode! buf "anon-local-mode")
          (with-stub 'anon--visible (lambda () '())
            (lambda ()
              (buffer-set-local! buf 'render-blocks tree)
              (let ((hidden (buffer-local buf 'render-blocks)))
                (set! anon--visible (lambda () (list buf)))
                (run-hook-with-args 'buffer-shown-hook buf)
                (let ((seen (buffer-local buf 'render-blocks)))
                  (disable-minor-mode! buf "anon-local-mode")
                  (check-equal! hidden tree "the hidden view is the tree its mode wrote")
                  (check-equal! (string-contains? (anon--tree-text seen) "Zelda") #f
                                "buffer-shown-hook bars the name in the view written while hidden")))))))
      (buffer-kill! buf))))

(deftest 'anon-a-write-redacts-only-the-parts-that-changed
  "the parts equal to the last tree take its redaction; only the new text goes to decide"
  (lambda ()
    (let ((old '((tag "c-transcript" children ((tag "div" text "Alice Smith wrote"))) (tag "c-prompt" text "")))
          (new '((tag "c-transcript" children ((tag "div" text "Alice Smith wrote"))) (tag "c-prompt" text "Bob Jones typed"))))
      (with-stub 'anon-common-words '()
        (lambda ()
          (let ((red (anon--redact-tree old)))
            (with-stub '*anon-new-text* '()
              (lambda ()
                (let* ((got (anon--redact-like new old red))
                       (fresh *anon-new-text*))
                  (check-equal! got (anon--redact-tree new) "the result is the redaction of the whole new tree")
                  (check-equal! fresh '("Bob Jones typed") "only the changed text is new"))))))))))

(deftest 'anon-unredact-gives-back-the-original-of-a-redacted-tree
  "a tree built from the redacted one gets its original text back, not the bars"
  (lambda ()
    (let ((orig '(div (span "Approve") (span "Ann Lee")))
          (red '(div (span "███████") (span "███████"))))
      (check-equal! (anon--unredact red red orig) orig "the redacted tree is the original")
      (check-equal! (anon--unredact '(div class "x" (span "███████")) red orig)
                    '(div class "x" (span "███████"))
                    "a part that does not line up stays as it came"))))

(deftest 'anon-learns-a-handle-that-holds-a-known-name
  "a lowercase token with a digit, dot or underscore that holds a name is a handle"
  (lambda ()
    (check-equal!
      (with-customs (list (list 'anon-proper-nouns '("Zyxwa Quorbel"))
                          (list 'anon-handles '()))
        (lambda ()
          (anon--learn-name-handles! "by zyxwaquorbel07 and zyxwa, jobs.page")
          anon-handles))
      '("zyxwaquorbel07") "only the token with a digit that holds the name")))
