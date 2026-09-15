;;; init.scm --- explicit bundled package boot order.
;;;
;;; The Elixir bootstrap loads editor.scm and the small stdlib first, then
;;; evaluates this file. Keep top-level package dependencies visible here. A
;;; compound package entry point loads its focused internal modules.
;;;
;;; (require 'NAME) loads NAME.scm from load-path once: priv, the project's
;;; scheme/packages, the config home, and its packages. The loader stamps
;;; each file's package and origin from the file, so a load needs no stamp
;;; around it, and provides the library name as a feature.
;;;
;;; After this file, Session evaluates ~/.compos/ai-config.scm,
;;; ~/.compos/init.scm, and ~/.compos/custom.scm. User packages therefore belong
;;; in ~/.compos/init.scm, for example:
;;;
;;;   (load "my-package.scm")
;;;
;;; The stock boot is the editor. An app the editor does not need ships in
;;; scheme/packages but loads on its first use: the ;;;###autoload cookies
;;; in its file name the commands M-x shows before the file loads, and the
;;; harvest at the end of this file installs them (amazon, doom, doom-lite,
;;; graphql, linkedin, movie, peers, px0, recording, spotify, spreadsheet,
;;; substack, title, training). A user init may still (load) one outright.
;;; The test suite loads them all (test/test_helper.exs).
;;;
;;; Order: a line here is a manifest line, not a proof. A package that
;;; needs another at load time says (require 'name) at its top, and a
;;; require of a loaded file is free, so the order below can only be
;;; wrong about speed, never about a name.

; the list buffer comes first: a package declares its lists at load, and
; dired is the first such package
; the transient menus come first: a package defines its prefixes at load
; the one-shot buffer migrations: packages register theirs at load
(require 'migrations)
(require 'transient)
(require 'tabulated-list)
; windows: display-buffer, the float, peek, layouts, special-mode, tiling;
; a list mode derives from special-mode at load, so this precedes dired
(require 'window)
(require 'tramp)
(require 'dired)
; the browser tabs join the switcher and the tools; sentry and code read it at load
(require 'chrome)
; the chat buffer and the LLM pipes: every package that opens a chat
; reads the chat locals lists at load
(require 'chat-mode)
; the modeline and the buffer-name grammar: every chrome names buffers
(require 'modeline)
(require 'isearch)
(require 'capf)
(require 'visual-line)
(require 'predict)
(require 'collect)
(require 'comint)
(require 'advice)
(require 'custom)
(require 'tools)
(require 'recipes)
(require 'components)
; the detail window: an app registers how it names a kept detail at load,
; so this comes before every app that opens rows into one
(require 'detail)
(require 'preview)
(require 'file-view)
; completion-at-point: agent-session.scm (under agent.scm) runs the chat
; mode hook on the chats already open, and that hook watches for
; completion. A cold boot has no chat open then; a Session restart does.
(require 'completion)
;; s-p: intent search over commands, recipes and past asks
(require 'palette)

(require 'anchor)
(require 'agenda)
(require 'agent)
(require 'annotate)
(require 'appearance)
(require 'autorevert)
(require 'bookmark)
(require 'register)
(require 'chat)
(require 'code)
(require 'daemons)
(require 'db)
(require 'diff-mode)
(require 'doppler)
(require 'endpoint)
(require 'irc)
(require 'evil)
(require 'feeds)
(require 'git)
(require 'google)
(require 'groups)
;; app identity: an app names the buffers of one instance, and a move
;; retags them through group membership, so this follows groups
(require 'apps)
(require 'help)
;; the task recipes for people (C-h h) and the generated manual
(require 'howto)
;; the learn-by-doing tutorial (C-h t); its companion chat is the training app
(require 'tutorial)
(require 'http)
(require 'ibuffer)
;; the buffers of one major mode, as ibuffer lists them
(require 'mode-list)
;; the chats table is the mode list of chat-mode: it loads after it
(require 'agent-fleet)
;; the spawn edges are the chats table's other view: it loads after it
(require 'subagents)
;; the event log: agents publish their status on it, so it follows the
;; chats table, whose status hook feeds it
(require 'events)
;; workflows: Scheme handlers over the event log that the core runs
;; exactly once; the demo scene is one you can drive (M-x events-demo)
(require 'workflows)
;; jobs on a clock; the workflow "cron" runs them, so it follows workflows
(require 'cron)
(require 'events-demo)
(require 'events-list)
(require 'notifications)
(require 'jj)
(require 'keys)
(require 'keymaps)
(require 'layouts)
;; the on-device decision model: it registers its daemon in the endpoint
;; registry, which models.scm reads to show and start it
(require 'laya)
(require 'lsp)
(require 'mcp-hub)
(require 'mcp)
;; the architecture canvas: one draw tool on the compos MCP, routed to a
;; backend (tldraw Desktop by default); it posts through http.scm
(require 'draw)
(require 'models)
;; the on-device tool caller: it fetches its engine and weights on the
;; first call, so a machine that never asks it pays nothing
(require 'needle)
(require 'whatsapp)
(require 'morg-kinds "morg/morg-kinds.scm")
(require 'morg)
(require 'markdown-mode)
(require 'cua)
(require 'notmuch)
(require 'occur)
(require 'org)
(require 'package)
(require 'paredit)
(require 'pdf)
(require 'project)
(require 'messages)
(require 'provenance)
(require 'scheme-ide)
;; the REPL is scheme-mode's other buffer: it derives its mode from scheme-mode
;; and binds C-c C-z and C-c C-e in it
(require 'repl)
(require 'peek)
;; popups after popper.el; its keys take the backtick family from groups.scm
(require 'popper)
(require 'scratch)
(require 'sentry)
(require 'setup)
(require 'skills)
(require 'prompts)
(require 'llm-config)
;; the Do prompt reads the whole command catalog: it loads after the apps
(require 'do)
;; the agents' shell commands in the sandbox: it reads the chat's llm-config
;; and its group, and the shell gate in decide.scm asks it
(require 'agent-sandbox)
;; a group's shared config lives in its home and reaches its buffers as they
;; join it; it may name a bundle, so it loads after llm-config
(require 'group-config)
;; the shared todo list: it sets a prompt part on every chat, so it follows
;; prompts, chat and the event log
(require 'todo)
(require 'sockets)
(require 'switch)
(require 'handheld)
(require 'telemetry)
(require 'perf)
(require 'profile)
(require 'test)
(require 'treesit)
(require 'web)
(require 'xslt)
(require 'web-server)
(require 'webhooks)
(require 'anon)
(require 'worktrees)
(require 'writing)
(require 'dismiss)
(require 'screenshot)

;; the run and result blocks live with the other blocks and lean on
;; block.scm; they load here because their kind registrations need the
;; registry, which boots with the packages
(require 'result-block "editor/blocks/result-block.scm")
(require 'run-block "editor/blocks/run-block.scm")
(require 'csv-block "editor/blocks/csv-block.scm")
(require 'table-block "editor/blocks/table-block.scm")
(require 'morg-tangle "morg/morg-tangle.scm")
(require 'morg-show-source "morg/morg-show-source.scm")
;; core editor behaviour, not a package: every URL and file path is a
;; link. It reads a buffer's directory (dired.scm), so it loads once the
;; stdlib is in, and it sweeps the buffers that exist by then.
(require 'goto-address "editor/goto-address.scm")

;; the autoloads: every unprovided file on load-path contributes the
;; commands its ;;;###autoload cookies name. The stock boot is complete
;; above; this is what makes the rest of scheme/packages reachable by name.
(autoload-harvest!)
