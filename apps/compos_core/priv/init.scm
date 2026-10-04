;;; init.scm --- explicit bundled package boot order.
;;;
;;; The Elixir bootstrap loads editor.scm and the small stdlib first, then
;;; evaluates this file. Keep top-level package dependencies visible here. A
;;; compound package entry point loads its focused internal modules.
;;;
;;; (load NAME) searches load-path: priv, the project's scheme/packages, the
;;; config home, and its packages. The loader stamps each file's package and
;;; origin from the file, so a load needs no stamp around it.
;;;
;;; After this file, Session evaluates ~/.compos/ai-config.scm,
;;; ~/.compos/init.scm, and ~/.compos/custom.scm. User packages therefore belong
;;; in ~/.compos/init.scm, for example:
;;;
;;;   (load "my-package.scm")
;;;
;;; The stock boot is the editor. An app the editor does not need ships in
;;; scheme/packages but loads only when the user init names it: amazon,
;;; doom, doom-lite, graphql, linkedin, movie, peers, px0, recording,
;;; spotify, spreadsheet, substack, title, training. The test suite loads
;;; them all (test/test_helper.exs).

; the list buffer comes first: a package declares its lists at load, and
; dired is the first such package
; the transient menus come first: a package defines its prefixes at load
; the one-shot buffer migrations: packages register theirs at load
(load "migrations.scm")
(load "transient.scm")
(load "tabulated-list.scm")
; windows: display-buffer, the float, peek, layouts, special-mode, tiling;
; a list mode derives from special-mode at load, so this precedes dired
(load "window.scm")
(load "tramp.scm")
(load "dired.scm")
; the browser tabs join the switcher and the tools; sentry and code read it at load
(load "chrome.scm")
; the chat buffer and the LLM pipes: every package that opens a chat
; reads the chat locals lists at load
(load "chat-mode.scm")
; the modeline and the buffer-name grammar: every chrome names buffers
(load "modeline.scm")
(load "isearch.scm")
(load "capf.scm")
(load "visual-line.scm")
(load "collect.scm")
(load "comint.scm")
(load "advice.scm")
(load "custom.scm")
(load "tools.scm")
(load "recipes.scm")
(load "components.scm")
; the detail window: an app registers how it names a kept detail at load,
; so this comes before every app that opens rows into one
(load "detail.scm")
(load "preview.scm")
(load "file-view.scm")
; completion-at-point: agent-session.scm (under agent.scm) runs the chat
; mode hook on the chats already open, and that hook watches for
; completion. A cold boot has no chat open then; a Session restart does.
(load "completion.scm")
;; s-p: intent search over commands, recipes and past asks
(load "palette.scm")

(load "anchor.scm")
(load "agenda.scm")
(load "agent.scm")
(load "annotate.scm")
(load "appearance.scm")
(load "autorevert.scm")
(load "bookmark.scm")
(load "register.scm")
(load "chat.scm")
(load "code.scm")
(load "daemons.scm")
(load "db.scm")
(load "diff-mode.scm")
(load "doppler.scm")
(load "endpoint.scm")
(load "irc.scm")
(load "evil.scm")
(load "feeds.scm")
(load "git.scm")
(load "google.scm")
(load "groups.scm")
;; app identity: an app names the buffers of one instance, and a move
;; retags them through group membership, so this follows groups
(load "apps.scm")
(load "help.scm")
;; the task recipes for people (C-h h) and the generated manual
(load "howto.scm")
;; the learn-by-doing tutorial (C-h t); its companion chat is the training app
(load "tutorial.scm")
(load "http.scm")
(load "ibuffer.scm")
;; the chats table is the ibuffer template over the chats: it loads after it
(load "agent-fleet.scm")
;; the spawn edges are the chats table's other view: it loads after it
(load "subagents.scm")
;; the event log: agents publish their status on it, so it follows the
;; chats table, whose status hook feeds it
(load "events.scm")
;; workflows: Scheme handlers over the event log that the core runs
;; exactly once; the demo scene is one you can drive (M-x events-demo)
(load "workflows.scm")
(load "events-demo.scm")
(load "events-list.scm")
(load "jj.scm")
(load "keys.scm")
(load "keymaps.scm")
(load "layouts.scm")
;; the on-device decision model: it registers its daemon in the endpoint
;; registry, which models.scm reads to show and start it
(load "laya.scm")
(load "lsp.scm")
(load "mcp-hub.scm")
(load "mcp.scm")
;; the architecture canvas: one draw tool on the compos MCP, routed to a
;; backend (tldraw Desktop by default); it posts through http.scm
(load "draw.scm")
(load "models.scm")
;; the on-device tool caller: it fetches its engine and weights on the
;; first call, so a machine that never asks it pays nothing
(load "needle.scm")
(load "whatsapp.scm")
(load "morg/morg-kinds.scm")
(load "morg.scm")
(load "markdown-mode.scm")
(load "cua.scm")
(load "notmuch.scm")
(load "occur.scm")
(load "org.scm")
(load "package.scm")
(load "paredit.scm")
(load "pdf.scm")
(load "project.scm")
(load "messages.scm")
(load "provenance.scm")
(load "scheme-ide.scm")
;; the REPL is scheme-mode's other buffer: it derives its mode from scheme-mode
;; and binds C-c C-z and C-c C-e in it
(load "repl.scm")
(load "peek.scm")
;; popups after popper.el; its keys take the backtick family from groups.scm
(load "popper.scm")
(load "scratch.scm")
(load "sentry.scm")
(load "setup.scm")
(load "skills.scm")
(load "prompts.scm")
(load "llm-config.scm")
;; the agents' shell commands in the sandbox: it reads the chat's llm-config
;; and its group, and the shell gate in decide.scm asks it
(load "agent-sandbox.scm")
;; a group's shared config lives in its home and reaches its buffers as they
;; join it; it may name a bundle, so it loads after llm-config
(load "group-config.scm")
;; the shared todo list: it sets a prompt part on every chat, so it follows
;; prompts, chat and the event log
(load "todo.scm")
(load "sockets.scm")
(load "switch.scm")
(load "handheld.scm")
(load "telemetry.scm")
(load "perf.scm")
(load "profile.scm")
(load "test.scm")
(load "treesit.scm")
(load "web.scm")
(load "xslt.scm")
(load "web-server.scm")
(load "webhooks.scm")
(load "anon.scm")
(load "worktrees.scm")
(load "writing.scm")
(load "dismiss.scm")
(load "screenshot.scm")

;; the run and result blocks live with the other blocks and lean on
;; block.scm; they load here because their kind registrations need the
;; registry, which boots with the packages
(load "editor/blocks/result-block.scm")
(load "editor/blocks/run-block.scm")
(load "editor/blocks/csv-block.scm")
(load "editor/blocks/table-block.scm")
(load "morg/morg-tangle.scm")
(load "morg/morg-show-source.scm")
;; core editor behaviour, not a package: every URL and file path is a
;; link. It reads a buffer's directory (dired.scm), so it loads once the
;; stdlib is in, and it sweeps the buffers that exist by then.
(load "editor/goto-address.scm")
