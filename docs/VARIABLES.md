# Variables

A global is a Scheme binding. A buffer-local is a key in the buffer.
These forms tie the two together the way Emacs does: a variable has one
default and, in a buffer that set it, a local value.

```scheme
(defvar 'fill-column 70 "The column past which lines wrap.")
(defvar-local 'indent-width 2)          ; variable-set! writes locally
(variable-value 'indent-width)          ; the buffer's own, else the default
(variable-set! 'indent-width 4)         ; local for a defvar-local, else global
(default-value 'indent-width)           ; the global
(set-default! 'indent-width 8)
(setq-local! 'indent-width 4)           ; the current buffer's own, always
(buffer-local-value 'indent-width buf)
(local-variable-p 'indent-width)
(kill-local-variable! 'indent-width)
```

`defvar` sets the default only when the name is unbound, so a reload
keeps a value the session set. `defcustom` in custom.scm is a `defvar`
with a saved value and a customize entry.

A local set to `#f` reads as absent. `buffer-local` answers `#f` for
both, and so does `local-variable-p`.

Buffer-local hooks are the same idea for hooks: see docs/HOOKS.md.
