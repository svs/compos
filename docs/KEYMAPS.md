# Keymaps

A keymap is a name, its own bindings, and a parent. The editor holds
every keymap in one table. A binding maps a key sequence, written as
Emacs writes it (`"C-x C-f"`, `"<f9> a"`), to a command name.

## The ladder

A key resolves down this ladder. An exact binding anywhere wins over a
prefix anywhere. A remap applies to the result.

1. The buffer's minor-mode maps, in order, first wins.
2. The global minor-mode maps (`cua-mode`).
3. The buffer's own map, then its parents.
4. The read-only map, when the buffer is read-only.
5. The global map.

This is Emacs's `minor-mode-map-alist`, then the local map, then the
global map. Transient and the key capture sit above the ladder in
`KeyDispatch`, as `overriding-terminal-local-map` does.

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

A minor mode registers its map with `register-minor-mode!`. While the
mode is on in a buffer, the map is in force there and leaves with the
mode. A global minor mode puts its map in `global-minor-maps!`.

```scheme
(define-keymap! "evil-local-mode-map")
(define-key "evil-local-mode-map" "j" "evil--key-j")
(register-minor-mode! "evil-local-mode" evil--setup! evil--teardown! "evil-local-mode-map")
```

## The API

| form | meaning |
|------|---------|
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
