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

## The hooks the editor runs

| hook | arguments | when |
|------|-----------|------|
| `pre-command-hook` | | before every command and every self-insert |
| `post-command-hook` | | after every command and every self-insert |
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
| `fs-change-hook` | ROOT | the watcher saw a change under ROOT |
| `group-membership-hook`, `group-kill-hook` | | see docs/groups.md |

`on-fs-change!`, `on-buffer-created!`, `on-buffer-woken!`,
`on-buffer-renamed!`, `on-buffer-shown!` are the older spellings of
`add-hook!` on those hooks.

Two tables are not hooks on purpose. `on-input-intent!` keys a handler
by intent type. `add-paste-hook!` keys a handler by mode and runs the
first that answers.
