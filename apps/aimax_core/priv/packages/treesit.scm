;;; treesit.scm --- install tree-sitter grammars from inside the editor.
;;;
;;; M-x ts-install-grammar clones a grammar repo, compiles its generated
;;; parser with cc, and loads it into the running NIF — no rebuild, no
;;; restart. Installed grammars live in ~/.aimax/grammars/ and reload at
;;; boot. Wire a grammar to a mode with (ts-mode "<lang>") — see the
;;; scheme-mode registration below.

(define *ts-known-grammars*
  '(("scheme" "https://github.com/6cdh/tree-sitter-scheme")
    ("python" "https://github.com/tree-sitter/tree-sitter-python")
    ("javascript" "https://github.com/tree-sitter/tree-sitter-javascript")
    ("css" "https://github.com/tree-sitter/tree-sitter-css")
    ("bash" "https://github.com/tree-sitter/tree-sitter-bash")
    ("ruby" "https://github.com/tree-sitter/tree-sitter-ruby")
    ("go" "https://github.com/tree-sitter/tree-sitter-go")
    ("c" "https://github.com/tree-sitter/tree-sitter-c")))

(define (ts-known-url name)
  (let ((e (assoc name *ts-known-grammars*)))
    (if e
        (car (cdr e))
        (string-append "https://github.com/tree-sitter/tree-sitter-" name))))

(define-command "ts-install-grammar" "Clone, compile, and load a tree-sitter grammar"
  (lambda ()
    (minibuffer-read "Grammar (language name): "
      (map (lambda (e) (list (car e) (car (cdr e)))) *ts-known-grammars*)
      (lambda (name)
        (unless (equal? name "")
          (minibuffer-read
            (string-append "Repo URL (default " (ts-known-url name) "): ") '()
            (lambda (url)
              (ts-install-grammar! name
                (if (equal? url "") (ts-known-url name) url))
              (message (string-append "grammar " name
                                      ": cloning and compiling…")))))))))

(define-command "ts-grammars" "Show loadable tree-sitter languages"
  (lambda ()
    (message (string-append
               "languages: " (string-join (ts-langs) " ")
               "  ·  installed: " (string-join (ts-installed-grammars) " ")))))

;; .scm/.el buffers highlight through the dynamic scheme grammar once
;; installed (M-x ts-install-grammar scheme); until then ts-lang is set
;; but the NIF just returns no spans
(define-mode "scheme-mode" (ts-mode "scheme"))

(category! 'syntax)
(public! 'ts-install-grammar! "(ts-install-grammar! NAME URL) — async grammar install")
