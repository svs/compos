;;; init.scm --- explicit bundled package boot order.
;;;
;;; The Elixir bootstrap loads editor.scm and the small stdlib first, then
;;; evaluates this file. Keep top-level package dependencies visible here. A
;;; compound package entry point loads its focused internal modules.
;;;
;;; After this file, Session evaluates ~/.compos/ai-config.scm,
;;; ~/.compos/init.scm, and ~/.compos/custom.scm. User packages therefore belong
;;; in ~/.compos/init.scm, for example:
;;;
;;;   (load "packages/my-package.scm")

(define (load-bundled-package file)
  (let* ((parts (string-split file "/"))
         (base (car (reverse parts)))
         (name (car (string-split base ".scm"))))
    (origin! 'bundled)
    (package! (string->symbol name))
    (load (string-append (compos-priv-dir) "/packages/" file))))

(load-bundled-package "custom.scm")
(load-bundled-package "tools.scm")
(load-bundled-package "recipes.scm")
(load-bundled-package "components.scm")
(load-bundled-package "preview.scm")
(load-bundled-package "file-view.scm")
(load-bundled-package "spreadsheet.scm")

(load-bundled-package "agenda.scm")
(load-bundled-package "agent.scm")
(load-bundled-package "annotate.scm")
(load-bundled-package "appearance.scm")
(load-bundled-package "autorevert.scm")
(load-bundled-package "bookmark.scm")
(load-bundled-package "register.scm")
(load-bundled-package "chat.scm")
(load-bundled-package "code.scm")
(load-bundled-package "daemons.scm")
(load-bundled-package "db.scm")
(load-bundled-package "diff-mode.scm")
(load-bundled-package "doppler.scm")
(load-bundled-package "endpoint.scm")
(load-bundled-package "irc.scm")
(load-bundled-package "evil.scm")
(load-bundled-package "feeds.scm")
(load-bundled-package "git.scm")
(load-bundled-package "graphql.scm")
(load-bundled-package "groups.scm")
(load-bundled-package "help.scm")
(load-bundled-package "ibuffer.scm")
(load-bundled-package "jj.scm")
(load-bundled-package "keys.scm")
(load-bundled-package "layouts.scm")
(load-bundled-package "lsp.scm")
(load-bundled-package "mcp-hub.scm")
(load-bundled-package "mcp.scm")
(load-bundled-package "morg/morg-kinds.scm")
(load-bundled-package "morg.scm")
(load-bundled-package "markdown-mode.scm")
(load-bundled-package "cua.scm")
(load-bundled-package "notmuch.scm")
(load-bundled-package "occur.scm")
(load-bundled-package "org.scm")
(load-bundled-package "package.scm")
(load-bundled-package "paredit.scm")
(load-bundled-package "pdf.scm")
(load-bundled-package "peers.scm")
(load-bundled-package "project.scm")
(load-bundled-package "messages.scm")
(load-bundled-package "provenance.scm")
(load-bundled-package "movie.scm")
(load-bundled-package "recording.scm")
(load-bundled-package "scheme-ide.scm")
(load-bundled-package "peek.scm")
(load-bundled-package "scratch.scm")
(load-bundled-package "sentry.scm")
(load-bundled-package "setup.scm")
(load-bundled-package "skills.scm")
(load-bundled-package "prompts.scm")
(load-bundled-package "sockets.scm")
(load-bundled-package "spotify.scm")
(load-bundled-package "switch.scm")
(load-bundled-package "telemetry.scm")
(load-bundled-package "perf.scm")
(load-bundled-package "test.scm")
(load-bundled-package "training.scm")
(load-bundled-package "treesit.scm")
(load-bundled-package "web.scm")
(load-bundled-package "web-server.scm")
(load-bundled-package "worktrees.scm")
(load-bundled-package "writing.scm")

(begin
  ;; the run and result blocks live with the other blocks and lean on
  ;; block.scm; they load here because their kind registrations need the
  ;; registry, which boots with the packages
  (origin! 'bundled)
  (package! 'result-block)
  (load (string-append (compos-priv-dir) "/editor/blocks/result-block.scm"))
  (origin! 'bundled)
  (package! 'run-block)
  (load (string-append (compos-priv-dir) "/editor/blocks/run-block.scm"))
  (origin! 'bundled)
  (package! 'csv-block)
  (load (string-append (compos-priv-dir) "/editor/blocks/csv-block.scm")))
(load-bundled-package "morg/morg-tangle.scm")
(load-bundled-package "morg/morg-show-source.scm")
;; core editor behaviour, not a package: every URL and file path is a
;; link. It reads a buffer's directory (dired.scm), so it loads once the
;; stdlib is in, and it sweeps the buffers that exist by then.
(begin
  (origin! 'bundled)
  (package! 'goto-address)
  (load (string-append (compos-priv-dir) "/editor/goto-address.scm")))
