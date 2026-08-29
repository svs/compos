;;; treesit-test.scm --- packages/treesit.scm: which grammar a mode asks for.
;;;
;;; The NIF is mechanism and stays in ExUnit: loading a bad library,
;;; installing a repository that is not a grammar, and the scopes a
;;; highlight answers with all call the Rust side directly. What a mode
;;; declares, and what the install surface offers, are Scheme.

(domain! 'testing)
(effects! '(write))

(define (t--treesit-lang! buf mode)
  (test-buffer! buf "")
  (switch-to-buffer! buf)
  (set-mode! mode)
  (buffer-local buf 'ts-lang))

(deftest 'a-mode-declares-the-grammar-its-buffers-are-parsed-with
  "ts-lang is the whole wiring: font lock and sexp nav both read it"
  (lambda ()
    (check-equal! (t--treesit-lang! "*zz-ts-scm*" "scheme-mode") "scheme" "scheme-mode")
    (check-equal! (t--treesit-lang! "*zz-ts-html*" "html-mode") "html" "html-mode")
    (buffer-kill! "*zz-ts-scm*")
    (buffer-kill! "*zz-ts-html*")))

(effects! '(read))

(deftest 'the-install-surface-names-a-repository-for-a-known-grammar
  "a person types a language, not a git URL"
  (lambda ()
    (check-contains! (ts-known-url "scheme") "6cdh/tree-sitter-scheme" "scheme")
    (check-contains! (ts-known-url "markdown") "tree-sitter-grammars/tree-sitter-markdown"
                     "markdown")
    (check-true! (pair? (member "elixir" (ts-langs))) "and a compiled grammar is listed")))
