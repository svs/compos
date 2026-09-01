# Modes

A major mode is a name, a setup function, a keymap, and a hook. A buffer
wears one major mode and any number of minor modes.

## Major modes

```scheme
(define-mode "text-mode" (lambda () ...))
(define-derived-mode "scratch-mode" "morg-mode" (lambda () ...))
(set-mode! "text-mode")
```

`define-mode` registers the setup, creates the keymap `NAME-map`, and
defines the command `NAME`. The command enters the mode. Running it in a
buffer that wears the mode keeps the mode, as in Emacs. The modeline
click is the toggle.

`define-derived-mode` makes NAME a child of PARENT: `NAME-map` falls
back to `PARENT-map`, the setup runs PARENT's setup first, and
`set-mode!` runs `PARENT-hook` before `NAME-hook`. `buffer-mode-is?`
answers true for the parent's name in the child's buffers.

`set-mode!` does this, in order:

1. `change-major-mode-hook`, when the buffer leaves another mode.
2. The buffer's own map and remaps are cleared, when the mode changes.
3. The buffer's own map takes `NAME-map` as its parent.
4. The setup runs.
5. The minor modes put their keys back, when the mode changed.
6. The hooks run, the root mode's first.
7. `after-change-major-mode-hook`.

A setup rebuilds keys, overlays, and folds from the locals it finds.
It runs on every entry, on desktop restore, and on hot reload.

`kill-all-local-variables!` forgets every local that is not permanent,
and the buffer's own keys. `set-mode!` does not call it: a local can
hold what a buffer is, and a mode change must not lose a chat. A mode
that wants a clean buffer calls it. `permanent-local!` marks a local as
one to keep. The chat identity locals are permanent.

## Minor modes

```scheme
(register-minor-mode! "paredit-mode" setup teardown "paredit-mode-map")
(enable-minor-mode! buf "paredit-mode")
(disable-minor-mode! buf "paredit-mode")
(toggle-minor-mode! "paredit-mode")
```

A minor mode is its name in the buffer-local `minor-modes` list. Turning
it on puts its keymap in force ahead of the buffer's own, runs the setup
with the buffer, then runs `NAME-hook` in the buffer. Turning it off
runs the teardown and takes the keymap away.

`define-globalized-minor-mode!` makes a command that turns a local mode
on in every buffer a predicate accepts, now and as buffers appear, and
off everywhere.

```scheme
(define-globalized-minor-mode! "evil-mode" "evil-local-mode" evil--eligible?)
```

## Which mode a file opens in

`auto-mode-for-buffer` asks, in order: `*magic-mode-alist*`, a regexp
on the first line; `*interpreter-mode-alist*`, the program a `#!` line
names; `*auto-mode-alist*`, the file name. An entry of the name list is
a suffix (`".scm"`) or a regexp (`"\\.scm$"`, `"^Makefile"`).
