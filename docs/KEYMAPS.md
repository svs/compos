# Keymaps

A keymap is a name, its own bindings, and a parent. The editor holds
every keymap in one table. A binding maps a key sequence, written as
Emacs writes it (`"C-x C-f"`, `"<f9> a"`), to a command name.

## The ladder

A key resolves down this ladder. An exact binding anywhere wins over a
prefix anywhere. A remap applies to the result.

1. The frame's overriding map: Transient's menu, or the prefix
   argument's `universal-argument-map`. A locked overriding map is the
   whole ladder, so an unbound key is undefined. While a prompt is up
   the overriding map waits, as Transient's does in Emacs.
2. The keymap of the thing at point: a fenced block's kind declares one,
   and morg sets it after every command. Emacs's overlay keymap.
3. The buffer's minor-mode maps, in order, first wins.
4. The global minor-mode maps (`cua-mode`).
5. The buffer's own map, then its parents.
6. The read-only map, when the buffer is read-only.
7. The global map.

Every printable key and SPC are bound to `self-insert-command` in the
global map, as in Emacs, so a key that inserts itself reaches a command
through a keymap like any other, and a mode can rebind a letter. The
same bindings in the ` *completion*` map make typing narrow the popup.
Only the key capture of `describe-key` sits above the ladder.

## Whose map is which

A buffer's own map is the keymap named after the buffer. `local-set-key`
writes there. `set-mode!` gives that map the mode's map as its parent,
so one `define-key` on the mode's map answers in every buffer that wears
the mode, and a buffer's own binding wins. A change of major mode
clears the buffer's own map and remaps, then the new mode's setup and
the minor modes put their keys back.

```scheme
(define-key (mode-keymap "scheme-mode") "M-." "scheme-goto-definition")
```

A core package binds on a map, never on a buffer. `mode-keys!` binds
once on the mode's map at load; `minor-mode-keys!` gives a minor mode
its map, in force while the mode is on and gone when it is off, so a
teardown unbinds nothing. A global minor mode puts its map in
`global-minor-maps!`. A buffer's own map is for the buffer itself: a
special buffer that is not a mode, or a user's one-off binding.

```scheme
(mode-keys! "pdf-reader-mode" '(("n" "pdf-next-page") ("p" "pdf-previous-page")))
(minor-mode-keys! "writing-mode" '(("M-<left>" "backward-word")))
```

Every list mode's map has `list-mode-map` as its parent: help, the
filter, the row motion, the marks and execute answer in every list, and
a list's own keys and flag keys go on its map when `define-list-mode!`
runs. A layout profile that brings flags of its own binds them on the
buffer, since the profile is buffer state. The popup's move keys are
`popup-mode`, on while the buffer floats.

`priv/tests/keys-sweep-test.scm` enters every major mode and every
minor mode in a fresh buffer and resolves each of its keys through the
ladder, so a dead key fails the sweep.

```scheme
(define-keymap! "evil-local-mode-map")
(define-key "evil-local-mode-map" "j" "evil--key-j")
(register-minor-mode! "evil-local-mode" evil--setup! evil--teardown! "evil-local-mode-map")
```

## Prefix keys

A prefix key leads to a keymap: the binding's value is `(keymap NAME)`,
and the rest of the sequence resolves in that keymap. editor.scm binds
the Emacs prefix maps in the global map: `ctl-x-map` on `C-x`,
`mode-specific-map` on `C-c`, `help-map` on `C-h`, `goto-map` on `M-g`,
`search-map` on `M-s`, and under `C-x`: `ctl-x-r-map`, `ctl-x-4-map`,
`project-prefix-map`, `vc-prefix-map`, `group-map` on `C-x C-g`. Under
`C-c`: `agent-map` on `a`, `spotify-map` on `S`, `annotate-map` on `!`.

A package binds into the map its keys belong to and never writes the
global map. `bind-prefix!` makes a new prefix. The listings, `where-is`
and `describe-key` walk through prefix maps, so `C-x r j` still reads
as one key.

```scheme
(define-key "ctl-x-r-map" "j" "jump-to-register")
(bind-prefix! "mode-specific-map" "S" "spotify-map")
```

## The API

| form | meaning |
|------|---------|
| `(mode-keys! MODE ((KEYS COMMAND) ...))` | bind once on the mode's map |
| `(minor-mode-keys! NAME ((KEYS COMMAND) ...))` | the minor mode's map |
| `(overriding-map! KEYMAP [LOCK?] [UNTIL-COMMAND?])` | the frame's overriding map |
| `(buffer-at-point-map! BUF KEYMAP)` | the keymap at point |
| `(define-keymap! NAME [PARENT])` | a named keymap |
| `(define-key KEYMAP KEYS COMMAND)`, `(keymap-set! ...)` | one binding |
| `(keymap-unset! KEYMAP KEYS)` | drop the keymap's own binding |
| `(keymap-parent! KEYMAP PARENT)`, `(keymap-parent KEYMAP)` | the parent |
| `(keymap-bindings KEYMAP)` | the keymap's own bindings |
| `(keymap-lookup KEYMAP KEYS)` | what KEYS means in the keymap and its parents |
| `(use-local-map! BUF KEYMAP)`, `(buffer-local-map BUF)` | the buffer's map takes a parent |
| `(clear-local-map! BUF)` | forget the buffer's own bindings and remaps |
| `(buffer-minor-maps! BUF NAMES)`, `(buffer-minor-maps BUF)` | the minor maps in force |
| `(global-minor-maps! NAMES)`, `(global-minor-maps)` | the maps in force everywhere |
| `(buffer-keymaps BUF)` | the ladder, by name |
| `(key-binding KEYS)`, `(key-binding-source KEYS)` | what a key does here, and which map said so |
| `(where-is-internal COMMAND [BUF])` | every key of a command |
| `(global-set-key KEYS COMMAND)`, `(local-set-key KEYS COMMAND)` | the global map, the buffer's own map |
