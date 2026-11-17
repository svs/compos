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
  (buffer-local-value 'ts-lang buf))

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

(deftest 'every-language-mode-is-built-from-prog-mode
  "one ancestor answers \"is this buffer source code\", and one hook reaches them all"
  (lambda ()
    (for-each
      (lambda (m) (check-true! (derived-mode? m "prog-mode") m))
      '("scheme-mode" "ruby-mode" "js-mode" "css-mode" "elixir-mode" "heex-mode"))
    (check-false! (derived-mode? "html-mode" "prog-mode")
                  "a browse page wears html-mode and is a document, not source")
    (check-false! (derived-mode? "text-mode" "prog-mode") "prose is not source")
    (check-equal! (mode-hook-chain "elixir-mode") '(prog-mode-hook elixir-mode-hook)
                  "the base hook runs before the language's own")))
