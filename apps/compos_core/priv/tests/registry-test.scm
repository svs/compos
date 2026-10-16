;;; registry-test.scm --- one name-to-value table for everything that keeps one.
;;;
;;; A mode's facts, a keyed hook's functions, an annotator per category,
;;; and in the packages an endpoint, a database, a GraphQL endpoint, a
;;; webhook and a fence kind each sit in a registry table. The rule they
;;; all lean on is proved here once: the same name registered again
;;; replaces its value in place, and nothing stacks. A package then tests
;;; only what it puts in.

(domain! 'testing)
(effects! '(write))

(define t--registry-table '(zz-registry-test))

(define (t--registry-reset!)
  (for-each (lambda (n) (registry-forget! t--registry-table n))
            (registry-names t--registry-table)))

(deftest 'a-registered-name-answers-its-value-and-an-unknown-one-the-default
  "lookup is by name; a name nobody registered answers the default"
  (lambda ()
    (t--registry-reset!)
    (registry-register! t--registry-table "a" '(command "cat"))
    (check-equal! (registry-lookup t--registry-table "a") '(command "cat") "the value")
    (check-equal! (registry-lookup t--registry-table "nobody") #f "an unknown name is #f")
    (check-equal! (registry-lookup t--registry-table "nobody" 'none) 'none "or the default given")
    (t--registry-reset!)))

(deftest 'registering-a-name-again-replaces-its-value-in-place
  "one name, one row: a reload never stacks a second entry, and the row keeps its place"
  (lambda ()
    (t--registry-reset!)
    (registry-register! t--registry-table "a" 1)
    (registry-register! t--registry-table "b" 2)
    (check-equal! (registry-register! t--registry-table "a" 3) "a" "register answers the name")
    (check-equal! (registry-lookup t--registry-table "a") 3 "the later value")
    (check-equal! (registry-list t--registry-table) '(("a" 3) ("b" 2))
                  "one row per name, in the order the names first came")
    (check-equal! (registry-names t--registry-table) '("a" "b") "the names likewise")
    (t--registry-reset!)))

(deftest 'forgetting-a-name-drops-it-and-says-whether-it-was-there
  "forget answers #t for a name it dropped and #f for one it never had"
  (lambda ()
    (t--registry-reset!)
    (registry-register! t--registry-table "a" 1)
    (check-true! (registry-forget! t--registry-table "a") "it was there")
    (check-false! (registry-forget! t--registry-table "a") "and now it is not")
    (check-equal! (registry-lookup t--registry-table "a") #f "the name is gone")
    (check-equal! (registry-list t--registry-table) '() "the table is empty")))

(deftest 'two-tables-keep-the-same-name-apart
  "a name in one table says nothing about the same name in another"
  (lambda ()
    (t--registry-reset!)
    (registry-register! t--registry-table "a" 'one)
    (registry-register! '(zz-registry-other) "a" 'two)
    (check-equal! (registry-lookup t--registry-table "a") 'one "the first table")
    (check-equal! (registry-lookup '(zz-registry-other) "a") 'two "the second table")
    (registry-forget! '(zz-registry-other) "a")
    (t--registry-reset!)))

;;; --- the tables the kernel keeps there ---------------------------------------
;;; Each port is proved by one round trip through the owner's own door.

(deftest 'a-keyed-hook-holds-its-functions-in-the-registry
  "the same key replaces its function, so a reload does not stack a second listener"
  (lambda ()
    (add-hook! '(zz-registry-hook "k") (lambda (x) 'first))
    (add-hook! '(zz-registry-hook "k") (lambda (x) 'second))
    (check-equal! (length (hook-functions '(zz-registry-hook "k"))) 1 "one function under the key")
    (check-equal! ((car (hook-functions '(zz-registry-hook "k"))) 'x) 'second "the later function runs")
    (check-equal! (length (registry-list '(hook zz-registry-hook))) 1 "one row in the table (hook HOOK)")
    (remove-hook! '(zz-registry-hook "k"))
    (check-equal! (hook-keys 'zz-registry-hook) '() "remove-hook! forgets the key")))

(deftest 'a-mode-fact-and-an-annotator-live-in-the-registry
  "mode-put! and marginalia! write their tables; a second write replaces, and forget empties"
  (lambda ()
    (let ((rows (length (registry-list 'mode))))
      (mode-icon! "zz-registry-mode" "a")
      (mode-icon! "zz-registry-mode" "b")
      (check-equal! (mode-icon "zz-registry-mode") "b" "the second glyph replaces the first")
      (check-equal! (length (registry-list 'mode)) (+ rows 1) "one row for the mode, however often it is declared")
      (mode-forget! "zz-registry-mode")
      (check-equal! (length (registry-list 'mode)) rows "forget drops the row"))
    (marginalia! 'zz-registry-cat (lambda (n) "first"))
    (marginalia! 'zz-registry-cat (lambda (n) "second"))
    (check-equal! (annotate 'zz-registry-cat (list "q")) '(("q" "second")) "the second annotator replaces the first")
    (registry-forget! 'marginalia 'zz-registry-cat)
    (check-equal! (annotate 'zz-registry-cat (list "q")) '("q") "no annotator: the names come back plain")))
