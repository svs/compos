# Editing minor modes: cua-mode, evil-mode, visual-line-mode

Three minor modes adapt how text selection, modal keys, and long lines behave across editing buffers.

## `cua-mode` (on by default)

`cua-mode` lets Shift + any motion key extend the selection, while keeping all standard Emacs keys (`C-a`, `C-e`, `C-k`, `C-w`, `C-y`, `C-SPC`) active.

- A buffer you just switched into stays in movement state until your first edit key, so Shift chords keep their navigation meaning until you start editing. Press `ESC` or `C-g` to return to movement state.
- Common chords: `S-<arrow>` (character or line), `C-S-<arrow>` or `M-S-<arrow>` (word), `S-Home`/`S-End` (line edges), `S-PageUp`/`S-PageDown` (screen), `s-a` (whole buffer).
- Chat buffers do not use `cua-mode`; use `C-SPC` to select text in a chat.
- Toggle with `M-x cua-mode`.

## `evil-mode` (Vim keys)

`evil-mode` adds Vim normal, insert, and visual states to text and code buffers while preserving special keys in chat, dired, mail, and terminals.

- Toggle globally with `M-x evil-mode`, or for one buffer with `M-x evil-local-mode`.
- Persist across restarts by adding `(evil-mode-on!)` to `~/.compos/init.scm`.
- Supports standard motions, operators, counts, `/` and `?` search, and `:w`, `:q`, `:wq`, and `:e FILE`.

## `visual-line-mode` (soft wrap)

Wraps long logical lines visually and moves `<up>`, `<down>`, `Home`, and `End` by rendered screen row while preserving goal column. Enabled automatically in `morg-mode`, `writing-mode`, and web pages; toggle anywhere with `M-x visual-line-mode`.

See also: [04. EVERYDAY EDITING](../04.%20EVERYDAY%20EDITING.md), [keys-mode](keys-mode.md).
