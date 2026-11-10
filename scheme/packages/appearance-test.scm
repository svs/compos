;;; appearance-test.scm --- how a keycap prints keys.
(domain! 'testing)
(effects! '(pure))

(deftest 'key-symbols-keycap-form
  "a modifier is its symbol, the hyphens stay, and the key keeps its case"
  (lambda ()
    (check-equal! (key-symbols "M-x") "⌥-x" "one modifier")
    (check-equal! (key-symbols "C-M-f") "⌃-⌥-f" "two modifiers keep their order")
    (check-equal! (key-symbols "s-P") "⌘-P" "a capital stays a capital")
    (check-equal! (key-symbols "C-x C-s") "⌃-x ⌃-s" "a sequence")
    (check-equal! (key-symbols "C-RET") "⌃-⏎" "a named key")
    (check-equal! (key-symbols "C--") "⌃--" "the minus key")
    (check-equal! (key-symbols "n") "n" "a key alone")
    (check-equal! (key-symbols "M-x find-file") "⌥-x find-file" "a name after the keys stays")
    (check-equal! (key-symbols "*Messages*") "*Messages*" "text that is not a key stays")
    (check-false! (key-symbol "C-") "a modifier with no key is not a key")))
