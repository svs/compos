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

(domain! 'system)
(effects! '(read))
(define (stdlib-dirs)
  "every package directory of the standard library"
  (map (lambda (e) (string-append stdlib-root "/" (substring (plist-get e 'name) 0 (- (string-length (plist-get e 'name)) 1))))
       (filter (lambda (e) (and (equal? (plist-get e 'type) "directory")
                                (not (string-prefix? "." (plist-get e 'name)))))
               (ls stdlib-root))))
(public! 'stdlib-dirs "(stdlib-dirs)\nEvery package directory of the standard library.")

(for-each (lambda (d) (unless (member d load-path) (set! load-path (append load-path (list d)))))
          (stdlib-dirs))

;; the stock set, in load order: (FEATURE) or (FEATURE "dir/file.scm")
(define stdlib-stock
  '(;; the page anchors every app reads by; core's lists and components call it once booted
    (anchor)
    ;; files that change on disk come back into their buffers
    (autorevert)
    (chrome)
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
    ;; images open fitted to the window; 1 shows them at their own size
    (image-view)
    ;; the images of a directory as a grid of thumbnails
    (gallery)
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
    ;; the writing surface: a centered measure, the font and line height of prose
    (writing)
    ;; ship a group to another daemon: M-x group-export, group-import, group-send
    (group-transfer)
    (cua)
    (vscode)
    (app-watch)
    (app-registry)
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
    ;; PDF files read and edited by their structure
    (pdf)
    ;; record voice samples and hear them cloned: M-x tts-training
    (tts-training)
    (morg-tangle "morg/morg-tangle.scm")
    (morg-show-source "morg/morg-show-source.scm")))

(for-each (lambda (e) (if (pair? (cdr e)) (require (car e) (cadr e)) (require (car e))))
          stdlib-stock)

(provide 'stdlib)
