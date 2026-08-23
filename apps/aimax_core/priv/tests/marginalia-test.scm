;;; marginalia-test.scm --- one annotator per category, read by every prompt.
;;;
;;; A candidate is a name. The annotation beside it is what a person needs
;;; to choose between two names that look alike. The fields become columns
;;; padded across the whole set, so the eye reads down a column.
;;;
;;; The prompt tests stay in ExUnit: they press C-x C-f and M-x, read the
;;; minibuffer the prompt opened, and build a directory of files.

(domain! 'testing)
(effects! '(write))

;; The registry is global and one entry per category. Every test takes its
;; own category out again.
(define (t--marg-forget! &rest categories)
  (for-each
    (lambda (c)
      (set! *marginalia* (remove (lambda (e) (equal? (car e) c)) *marginalia*)))
    categories))

(deftest 'annotate-pairs-names-with-their-categorys-annotator
  "a category nobody annotates hands its candidates back untouched"
  (lambda ()
    (marginalia! 'zzmarg-one (lambda (n) (string-append "<" n ">")))
    (check-equal! (annotate 'zzmarg-one (list "a" "bb"))
                  '(("a" "<a>") ("bb" "<bb>")) "each name with its annotation")
    (check-equal! (annotate 'zzmarg-nobody (list "x" "y"))
                  '("x" "y") "an unannotated category is untouched")
    (t--marg-forget! 'zzmarg-one)))

(deftest 'several-fields-become-columns-padded-across-the-whole-set
  "the second field starts in the same place on every row"
  (lambda ()
    (marginalia! 'zzmarg-cols (lambda (n) (list n "z")))
    ;; "a" pads to the width of "bbb"
    (check-equal! (annotate 'zzmarg-cols (list "a" "bbb"))
                  '(("a" "a    z") ("bbb" "bbb  z")) "one width for the set")
    (t--marg-forget! 'zzmarg-cols)))

(deftest 'a-row-whose-last-fields-say-nothing-ends-early
  "padding to a column nobody filled is trailing space"
  (lambda ()
    (marginalia! 'zzmarg-trim
      (lambda (n) (if (equal? n "a") (list "" "") (list "x" "yy"))))
    (check-equal! (annotate 'zzmarg-trim (list "a" "b"))
                  '(("a" "") ("b" "x  yy")) "the empty row ends")
    (t--marg-forget! 'zzmarg-trim)))

(deftest 'marginalia-registers-an-annotator-and-replaces-one
  "one annotator per category: the second registration wins"
  (lambda ()
    (marginalia! 'zzmarg-cat (lambda (n) (string-append "<" n ">")))
    (check-equal! (annotate 'zzmarg-cat (list "q")) '(("q" "<q>")) "the first")
    (marginalia! 'zzmarg-cat (lambda (n) "second"))
    (check-equal! (annotate 'zzmarg-cat (list "q")) '(("q" "second")) "the second replaces it")
    (t--marg-forget! 'zzmarg-cat)))

(deftest 'define-command-stores-a-docstring-that-command-doc-reads-back
  "the doc is what the M-x list shows beside the name"
  (lambda ()
    (define-command "zzmarg-frob" "Frob the marginalia test" (lambda () #t))
    (check-equal! (command-doc "zzmarg-frob") "Frob the marginalia test" "the doc")
    ;; the 2-arity form still works, and reads as an empty doc
    (define-command "zzmarg-plain" (lambda () #t))
    (check-equal! (command-doc "zzmarg-plain") "" "no doc is the empty string")
    (test-forget-catalog! "command" "zzmarg-frob")
    (test-forget-catalog! "command" "zzmarg-plain")))
