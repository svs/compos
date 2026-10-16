;;; treesit.scm --- install tree-sitter grammars from inside the editor.
;;;
;;; M-x ts-install-grammar clones a grammar repo, compiles its generated
;;; parser with cc, and loads it into the running NIF — no rebuild, no
;;; restart. Installed grammars live in ~/.compos/grammars/ and reload at
;;; boot. Wire a grammar to a mode with (ts-mode "<lang>") — see the
;;; scheme-mode registration below.

(define *ts-known-grammars*
  '(("scheme" "https://github.com/6cdh/tree-sitter-scheme")
    ("python" "https://github.com/tree-sitter/tree-sitter-python")
    ("javascript" "https://github.com/tree-sitter/tree-sitter-javascript")
    ("css" "https://github.com/tree-sitter/tree-sitter-css")
    ("html" "https://github.com/tree-sitter/tree-sitter-html")
    ("elixir" "https://github.com/elixir-lang/tree-sitter-elixir")
    ("heex" "https://github.com/phoenixframework/tree-sitter-heex")
    ("bash" "https://github.com/tree-sitter/tree-sitter-bash")
    ("ruby" "https://github.com/tree-sitter/tree-sitter-ruby")
    ("go" "https://github.com/tree-sitter/tree-sitter-go")
    ("markdown" "https://github.com/tree-sitter-grammars/tree-sitter-markdown")
    ("c" "https://github.com/tree-sitter/tree-sitter-c")
    ("diff" "https://github.com/tree-sitter-grammars/tree-sitter-diff")))

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

;; Every language mode here is built from prog-mode, so one hook and one
;; map reach all of them, and (buffer-derived-mode? BUF "prog-mode")
;; answers "is this buffer source code" for every one.

;; .scm/.el buffers highlight through the dynamic scheme grammar once
;; installed (M-x ts-install-grammar scheme); until then ts-lang is set
;; but the NIF just returns no spans
(define-derived-mode "scheme-mode" "prog-mode" (ts-mode "scheme"))

;; ruby and javascript ride the same dynamic-grammar path; without the
;; grammar the mode still works (and an LSP server still attaches)
(define-derived-mode "ruby-mode" "prog-mode" (ts-mode "ruby"))
(define-derived-mode "js-mode" "prog-mode" (ts-mode "javascript"))

;; The editor's own surfaces are Elixir, HEEx, HTML and CSS, so those
;; four read structurally too. Two of the names already existed without
;; a mode behind them: lsp.scm registers elixir-ls for "elixir-mode",
;; and browse sets "html-mode" on a page it renders.
;;
;; html-mode stays outside prog-mode for that last reason: a browse page
;; is a document the reader never edits, and prog-mode-hook must not run
;; on it. A .html file still parses and highlights the same way.
(define-derived-mode "css-mode" "prog-mode" (ts-mode "css"))
(define-mode "html-mode" (ts-mode "html"))
(define-derived-mode "elixir-mode" "prog-mode" (ts-mode "elixir"))
(define-derived-mode "heex-mode" "prog-mode" (ts-mode "heex"))

(mode-doc! "ruby-mode"
  "Ruby. Run `M-x ts-install-grammar ruby` to get the colours.")
(mode-doc! "js-mode"
  "JavaScript. Run `M-x ts-install-grammar javascript` to get the colours.")
(mode-doc! "css-mode"
  "CSS. Run `M-x ts-install-grammar css` to get the colours.")
(mode-doc! "html-mode"
  "HTML. Run `M-x ts-install-grammar html` to get the colours.")
(mode-doc! "elixir-mode"
  "Elixir. Run `M-x ts-install-grammar elixir` to get the colours.")
(mode-doc! "heex-mode"
  "HEEx: the Phoenix template language. Run `M-x ts-install-grammar heex` to get the colours.")

(set! *auto-mode-alist*
  (append *auto-mode-alist*
          '((".rb" "ruby-mode")
            (".js" "js-mode") (".mjs" "js-mode") (".jsx" "js-mode")
            (".css" "css-mode")
            (".html" "html-mode") (".htm" "html-mode")
            (".ex" "elixir-mode") (".exs" "elixir-mode")
            (".heex" "heex-mode"))))

(mode-doc! "scheme-mode"
  "Scheme: the language the editor is written in. `C-M-f` and `C-M-b` step over forms, and `M-g i` lists the definitions. Run `M-x ts-install-grammar scheme` to get the colours.")

(category! 'syntax)
(public! 'ts-install-grammar! "(ts-install-grammar! NAME URL) — async grammar install")

;; ComposML documents use HTML syntax with a semantic vocabulary.
(domain! 'syntax)
(effects! '(write display))
(define-mode "composml-mode" (ts-mode "html"))
(mode-doc! "composml-mode"
  "Edit semantic ComposML documents with the built-in HTML grammar. Semantic queries select domain tag names.")
(set! *auto-mode-alist*
  (cons '(".composml" "composml-mode")
        (remove (lambda (entry) (equal? (car entry) ".composml")) *auto-mode-alist*)))

;; Python, shell, Go and C read structurally once their grammar is in;
;; until then they outline by indentation, the way ruby and js do.
(define-derived-mode "python-mode" "prog-mode" (ts-mode "python"))
(define-derived-mode "sh-mode" "prog-mode" (ts-mode "bash"))
(define-derived-mode "go-mode" "prog-mode" (ts-mode "go"))
(define-derived-mode "c-mode" "prog-mode" (ts-mode "c"))
(set! *auto-mode-alist*
  (append (remove (lambda (entry) (member (car entry) '(".py" ".sh" ".bash" ".go" ".c" ".h")))
                  *auto-mode-alist*)
          '((".py" "python-mode") (".sh" "sh-mode") (".bash" "sh-mode")
            (".go" "go-mode") (".c" "c-mode") (".h" "c-mode"))))

;; A reader that meets a mode whose grammar is not loaded installs it and
;; waits, so it gets the tree and not the indentation fallback. The install
;; gives no word when it ends, so the wait watches ts-langs; it belongs on
;; the reader's own lane or task, never the ui lane. Each language is tried
;; once a session, so a grammar that does not build costs one wait, not one
;; per read.
(define *ts-install-tried* '())

(define (ts-ensure-grammar! lang &optional seconds)
  (cond ((not (string? lang)) #f)
        ((member lang (ts-langs)) #t)
        ((or (member lang *ts-install-tried*) (not (assoc lang *ts-known-grammars*))) #f)
        (else
         (set! *ts-install-tried* (cons lang *ts-install-tried*))
         (ts-install-grammar! lang (ts-known-url lang))
         (wait-until (lambda () (member lang (ts-langs))) (* 1000 (or seconds 180)) 250)
         (and (member lang (ts-langs)) #t))))

(effects! '(read))
(public! 'ts-langs "(ts-langs) — the names of the loaded tree-sitter languages")
(public! 'ts-installed-grammars "(ts-installed-grammars) — the names of the installed tree-sitter grammars")
(effects! '(write external execute))
(public! 'ts-ensure-grammar! "(ts-ensure-grammar! LANG [SECONDS]) — #t once LANG's grammar is loaded: a known grammar not loaded yet is installed and waited for, once a session")
