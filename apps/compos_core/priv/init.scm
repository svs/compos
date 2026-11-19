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
;;; The stock boot is the editor. An app ships in scheme/apps, which is
;;; nothing special: one more load-path entry, so it loads on its first use: the ;;;###autoload cookies
;;; in its file name the commands M-x shows before the file loads, and the
;;; harvest at the end of this file installs them (title). A user init may
;;; still (load) one outright.
;;; A community package lives in its own repo and loads with use-package
;;; from ~/.compos/init.scm, after this file.
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
; windows: the public doors (display-buffer, the float, previews,
; quit-window, the tiling commands) over the window model; it precedes dired
(require 'window)
(require 'tramp)
(require 'dired)
; the modeline and the buffer-name grammar: every chrome names buffers
(require 'modeline)
(require 'capf)
(require 'advice)
(require 'custom)
;; the settings of the windows: bound before any package reads one
(require 'window-settings)
(require 'components)
;; the hand keys and / over an index's and a detail's tab bars
(require 'tab-bars)
; the detail window: an app registers how it names a kept detail at load,
; so this comes before every app that opens rows into one
(require 'detail)
; completion-at-point: agent-session.scm (under agent.scm) runs the chat
; mode hook on the chats already open, and that hook watches for
; completion. A cold boot has no chat open then; a Session restart does.
(require 'completion)
;; s-p: intent search over commands and past asks
(require 'palette)

(require 'appearance)
(require 'daemons)
(require 'db)
;; the window model: a row of panes, each a stack of windows, each a stack
;; of buffers, and the policy that says where a buffer opens. groups.scm
;; keeps one per group, so it comes first
(require 'panes)
(require 'groups)
;; windows have names: C-x j switch-window, M-x window-rename
(require 'window-names)
;; every change of the windows, as it happened: M-x debug-last-window-movement
(require 'window-log)
;; the window model on the frame: the only window system
(require 'panes-mode)
;; undo and redo over the pane arrangement alone: M-x layout-undo, layout-redo
(require 'panes-history)
;; app identity: an app names the buffers of one instance, and a move
;; retags them through group membership, so this follows groups
(require 'apps)
(require 'http)
;; the event log: agents publish their status on it, so it follows the
;; chats table, whose status hook feeds it
(require 'events)
;; jobs on a clock; the workflow "cron" runs them, so it follows workflows
(require 'cron)
(require 'events-demo)
(require 'watchers)
(require 'keys)
(require 'keymaps)
(require 'package)
(require 'messages)
;; popups after popper.el; its keys take the backtick family from groups.scm
(require 'popper)
(require 'scratch)
(require 'prompts)
(require 'holds)
;; a group's shared config lives in its home and reaches its buffers as they
;; join it; it may name a bundle, so it loads after llm-config
(require 'group-config)
(require 'switch)
;; the model rounds and tool calls of an ACP or Codex turn, for chat-perf
(require 'agent-perf)
(require 'perf)
;; which compos is running: rel VERSION · COMMIT, or dev · jj · git
(require 'build-identity)
;; packages follow the release: hold, rollback, and a fix todo when an
;; update breaks an API your code uses. It reads build-info, so it follows
;; build-identity
(require 'package-update)
(require 'profile)
(require 'dismiss)

;; the standard library: chat, agents, todo, git, code and the everyday
;; set, one directory each in scheme/stdlib (a release carries it in
;; priv/stdlib). stdlib.scm loads the stock set in the order this file
;; used to.
(require 'stdlib)

;; the run and result blocks live with the other blocks and lean on
;; block.scm; they load here because their kind registrations need the
;; registry, which boots with the packages
(require 'result-block "editor/blocks/result-block.scm")
(require 'run-block "editor/blocks/run-block.scm")
(require 'csv-block "editor/blocks/csv-block.scm")
(require 'table-block "editor/blocks/table-block.scm")
;; core editor behaviour, not a package: every URL and file path is a
;; link. It reads a buffer's directory (dired.scm), so it loads once the
;; stdlib is in, and it sweeps the buffers that exist by then.
(require 'goto-address "editor/goto-address.scm")

;; the autoloads: every unprovided file on load-path contributes the
;; commands its ;;;###autoload cookies name. The stock boot is complete
;; above; this is what makes the rest of scheme/packages reachable by name.
(autoload-harvest!)
