;;; emacs-names-test.scm --- the Emacs names keep Emacs' argument order and answers.

(require 'emacs-names)

(deftest 'emacs-names-strings-answer-as-emacs-does
  "string-search takes the needle first and answers a character index; split-string cuts at a regexp, white space by default"
  (lambda ()
    (check-equal! (string-search "b" "aéb") 2 "a character index, not a byte offset")
    (check-equal! (string-search "a" "abca" 1) 3 "START skips the first")
    (check-false! (string-search "z" "abc") "no match is #f")
    (check-equal! (split-string " a b\n c  ") '("a" "b" "c") "white space, empty parts dropped")
    (check-equal! (split-string "a\n\nb" "\n") '("a" "" "b") "a separator keeps empty parts")
    (check-equal! (split-string "a\n\nb" "\n" #t) '("a" "b") "OMIT-NULLS drops them")
    (check-equal! (split-string "a,b;c" "[,;]") '("a" "b" "c") "SEPARATORS is a regexp")))

(deftest 'emacs-names-lists-and-paths
  "mapcar and make-list build lists; expand-file-name puts a relative name under DIR"
  (lambda ()
    (check-equal! (mapcar (lambda (x) (* 2 x)) '(1 2)) '(2 4) "mapcar is map")
    (check-equal! (make-list 2 'x) '(x x) "N copies of INIT")
    (check-equal! (expand-file-name "a.txt" "/tmp") "/tmp/a.txt" "relative under DIR")
    (check-equal! (expand-file-name "/etc/hosts" "/tmp") "/etc/hosts" "absolute stays")))

(deftest 'emacs-names-symbol-file-names-the-defining-file
  "symbol-file answers the package file of a catalogued name, and #f for a builtin or an unknown name"
  (lambda ()
    (check-true! (string-suffix? "/emacs-names.scm" (symbol-file 'symbol-file)) "a package function gives its file")
    (check-false! (symbol-file 'symbol-file 'defvar) "defvar skips functions")
    (check-false! (symbol-file 'emacs-names-test-no-such-name) "an unknown name is #f")))
