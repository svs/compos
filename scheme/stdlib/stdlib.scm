;;; stdlib.scm --- the standard library of compos.
;;;
;;; Three levels of Scheme: core (priv/*.scm and scheme/packages), the
;;; standard library here in scheme/stdlib, and the packages that live in
;;; their own repos and load with use-package. A name is defined at one
;;; level only (stdlib-test.scm checks it).
;;;
;;; One directory for each package. This file puts every one of them on
;;; load-path, so (require 'NAME) finds NAME/NAME.scm, then loads the stock
;;; set in the order the stock boot has always used. A package not in the
;;; stock set loads on first use: its ;;;###autoload cookies are harvested
;;; with the rest at the end of core's init.scm, which loads this file with
;;; (require 'stdlib). A checkout loads it from scheme/stdlib; a release
;;; carries it in compos_core's priv/stdlib.

(define stdlib-root
  (let ((root (compos-project-dir)))
    (if (and root (file-directory? (string-append root "/scheme/stdlib")))
        (string-append root "/scheme/stdlib")
        (string-append (compos-priv-dir) "/stdlib"))))

(define (stdlib-dirs)
  "every package directory of the standard library"
  (map (lambda (e) (string-append stdlib-root "/" (substring (plist-get e 'name) 0 (- (string-length (plist-get e 'name)) 1))))
       (filter (lambda (e) (and (equal? (plist-get e 'type) "directory")
                                (not (string-prefix? "." (plist-get e 'name)))))
               (ls stdlib-root))))

(for-each (lambda (d) (unless (member d load-path) (set! load-path (append load-path (list d)))))
          (stdlib-dirs))

;; the stock set, in load order: (FEATURE) or (FEATURE "dir/file.scm")
(define stdlib-stock
  '((chrome)
    (chat-mode)
    (isearch)
    (visual-line)
    (collect)
    (comint)
    (tool-results)
    (tools)
    (model-rules)
    (index)
    (preview)
    (file-view)
    (agent-machine)
    (agent)
    (bookmark)
    (register)
    (chat)
    (code)
    (decide)
    (jev)
    (diff-mode)
    (evil)
    (git)
    (panes-board)
    (pane-overview)
    (window-flash)
    (help)
    (howto)
    (tutorial)
    (ibuffer)
    (peek)
    (mode-list)
    (agent-fleet)
    (subagents)
    (workflows)
    (self-healing)
    (help-chat)
    (events-list)
    (ai)
    (jj)
    (lsp)
    (mcp-hub)
    (mcp)
    (models)
    (morg-kinds "morg/morg-kinds.scm")
    (morg)
    (markdown-mode)
    (cua)
    (vscode)
    (app-watch)
    (occur)
    (paredit)
    (project)
    (provenance)
    (scheme-ide)
    (repl)
    (setup)
    (setup-wizard)
    (skills)
    (llm-config)
    (llm-gate)
    (agent-sandbox)
    (todo)
    (agent-listen)
    (llm-costs)
    (telemetry)
    (release)
    (test)
    (treesit)
    (tree-edit)
    (worktrees)
    (content-scale)
    (morg-tangle "morg/morg-tangle.scm")
    (morg-show-source "morg/morg-show-source.scm")))

(for-each (lambda (e) (if (pair? (cdr e)) (require (car e) (cadr e)) (require (car e))))
          stdlib-stock)

(provide 'stdlib)
