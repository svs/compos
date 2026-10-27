# Hooks

A hook is a name and a list of functions. The editor runs a hook at a
seam, and a package puts a function on the hook to act there. Every
hook is Scheme, in `editor.scm`.

## The API

```scheme
(add-hook! 'find-file-hook 'my-package--on-visit)      ; once, first
(add-hook! 'find-file-hook 'my-package--on-visit #t)   ; once, last
(add-hook! 'find-file-hook 'my-package--on-visit #f #t) ; this buffer only
(remove-hook! 'find-file-hook 'my-package--on-visit)
(hook-functions 'find-file-hook)                       ; local, then global
(run-hooks 'find-file-hook 'other-hook)                ; no arguments
(run-hook-with-args 'buffer-renamed-hook old new)
(run-hook-with-args-until-success 'paste-hook kind data)
(run-hook-with-args-until-failure 'may-save-hook buf)
```

Give `add-hook!` the name of a function, quoted. The name is looked up
when the hook runs. A reload that redefines the function changes what
runs, and adding the name again is a no-op, so a package registers at
its top level with no guard. A closure works too, but a closure is a
fresh value after every reload, so it is added again each time the file
loads.

A local hook lives on the current buffer and runs before the global
list. The local table lives in Scheme, keyed by buffer name.

A keyed hook, `(add-hook! '(block-click diff) FN)`, holds one function
per key, and the same key replaces, so a reload stacks nothing. Since
2026-10-16 the keyed functions live in the registry table `(hook HOOK)`,
with the mode table, the annotators and every package registry
(`registry-register!`, `registry-lookup`, `registry-forget!`,
`registry-list`). Before that they lived in `*keyed-hooks*`.

A store that a kernel reload moves needs a one-shot carry-over beside
the new readers: a reload of editor.scm into a running daemon redefines
the readers to the new store while the old global still holds every
entry, and until something moves them nothing runs. On 2026-10-16 that
emptied agent-turn-end, block-click, preview-link, display-action and
context-provider at once. `hook--carry-keyed!` is the pattern: when the
old global is bound and non-empty, register each entry into the new
store, then set the old global to `'()` so a second load moves nothing
twice. registry-test.scm checks it.

## The hooks the editor runs

| hook | arguments | when |
|------|-----------|------|
| `pre-command-hook` | | before every command and every self-insert |
| `post-command-hook` | | after every command and every self-insert |
| `point-motion-hook` | BUF | the client's caret moved point in the editing state, with no command (editor_live.ex `sel`) |
| `find-file-hook` | | after the visit command opened a file |
| `before-save-hook`, `after-save-hook` | | around a save |
| `MODE-hook` | | after `set-mode!` ran the mode's setup |
| `frame-attach-hook` | | a client mounted a frame |
| `window-configuration-change-hook` | | a frame's windows or their buffers changed |
| `theme-change-hook` | | after `load-theme` |
| `buffer-created-hook` | NAME | a new buffer has its text |
| `buffer-woken-hook` | NAME | a dormant buffer came back |
| `buffer-renamed-hook` | OLD NEW | `rename-buffer!` |
| `buffer-shown-hook` | BUFFER | the switcher filled a window |
| `buffer-refresh-hook` | BUFFER KEYS | a window shows BUFFER, and `buffer-mark-dirty!` left KEYS pending |
| `fs-change-hook` | ROOT | the watcher saw a change under ROOT |
| `editing-state-hook` | BUF | the buffer entered or left the editing state |
| `llm-config-changed-hook` | BUF | llm-config exited and the buffer's setup changed |
| `group-membership-hook`, `group-kill-hook` | | see docs/groups.md |
| `group-joined-hook` | BUF ID | BUF is in group ID now, by any way in (buffer-joined-group!) |

`on-fs-change!`, `on-buffer-created!`, `on-buffer-woken!`,
`on-buffer-renamed!`, `on-buffer-shown!` are the older spellings of
`add-hook!` on those hooks.

Two tables are not hooks on purpose. `on-input-intent!` keys a handler
by intent type. `add-paste-hook!` keys a handler by mode and runs the
first that answers.

### Dashboard presentation

`dashboard--sync!` rebuilds presentation only when a window in any frame shows the buffer.
Hidden updates call `(buffer-mark-dirty! BUF 'dashboard)`. Repeated updates keep one pending refresh.
`buffer-refresh-hook` consumes that refresh when the buffer appears.
Restore requests a new sync; the `dirty?` local is not saved in the desktop.

### Refresh when shown

A package that skips work on a hidden buffer calls `(buffer-mark-dirty! BUF KEY)`.
The one `dirty?` local holds the pending keys. When a window shows the buffer
(`buffer-shown-hook` or `window-configuration-change-hook`), the kernel clears the
keys and runs `buffer-refresh-hook` one time with `(BUF KEYS)`. Each handler acts
on its own key; a handler that must wait marks again. `(buffer-dirty? BUF [KEY])`
asks, and `(buffer-clear-dirty! BUF KEY)` drops a key the package did another way.
Keys today: `dashboard`, `group-display`, `todo-cards`, `diff`, `anon`.
