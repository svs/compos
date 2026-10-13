# cua-mode

Shift with a motion key extends the region. That is the whole of cua-mode:
fifteen keys and the `cua-select-*` commands they run, in
`scheme/packages/cua.scm`. It is Emacs's `cua-mode` and
`shift-select-mode` in one. It is on from boot, and `M-x cua-mode` toggles it.

## The keys

| Key | Extends the region |
|-----|--------------------|
| `S-<left>` `S-<right>` | one character |
| `S-<up>` `S-<down>` | one visual line |
| `S-<home>` `S-<end>` | to the start or the end of the line |
| `C-S-<left>` `C-S-<right>` | one word |
| `M-S-<left>` `M-S-<right>` | one word (the macOS shape) |
| `C-S-<home>` `C-S-<end>` | to the start or the end of the buffer |
| `S-<prior>` `S-<next>` | one screen |
| `s-a` | the whole buffer (`cua-select-all`) |

Each command starts a region at point when there is none, and extends the one
that is there. They move by the same primitives as the plain motions, so a
mode that changes what a line or a word is changes the selections with it.

`M-S-<left>` and `M-S-<right>` move between groups where you are not editing
(`groups.scm` binds them in the global map). cua-mode's map answers ahead of
the global one, so the chord extends the selection in a buffer you are
editing. Press `ESC` first, or use the group prefix, to move between groups
from a buffer you are editing.

## Where it answers

cua-mode owns one keymap, `cua-mode-map`, and the map is in force only in a
buffer you are editing.

A buffer you have just landed on is in the movement state, and there the Shift
chords keep their plain meaning: `S-<left>` walks buffer history and
`M-S-<left>` moves to the group on the left. The first key that says you are
editing here (a letter, RET, a plain arrow, anything but the Shift chords
themselves) arms the editing state, and the selections come with it. `ESC` or
`C-g` returns the buffer to the movement state, and so does a window command
or a new landing. A read-only buffer never leaves the movement state, so
Shift never selects there.

The gate is the editing state in `editor.scm`, and not code of cua's own:
`cua.scm` adds `cua-mode-map` to `*editing-state-maps*`, and
`editing-state-on!` installs the maps on that list. The chords themselves are
neutral commands (`editing-neutral-commands!`): pressing one says nothing
about whether you are editing here, so it neither arms the state nor leaves it.

## What it is not

cua-mode is not the Emacs keys. `C-a`, `C-e`, `C-k`, `C-f`, `C-b`, `C-n`,
`C-p`, `C-d`, `M-f`, `M-b`, `C-y`, `M-w`, `C-w` and `C-SPC` are bound in the
global map (`editor.scm`, the default keymap section) and answer in every
buffer, through the ladder in `docs/KEYMAPS.md`. cua-mode binds none of them,
and `M-x cua-mode` off takes none of them away. Cmd-C and Cmd-V are not cua's
either: the client handles those.

## Chat buffers

A chat window has no `contenteditable` node, so the browser never keeps a key
for its own text pipeline there. Every key travels to the server and resolves
through the keymap ladder, and the Emacs keys answer in a chat exactly as they
do in a file buffer: `C-a` goes to the start of the line, `C-k` kills to the
end of it, `C-y` yanks.

Selection is the part that should differ. The decision is that a chat is not
a cua surface: a chat is a conversation with an input, and the Shift chords
there are worth more as the buffer walk than as a region.

`editing-state-maps-off!` lets a mode refuse one map of the state, and
chat-mode refuses both `editing-caret-map` and `cua-mode-map`. A chat you have
typed into is in the editing state, but `S-<left>` and `S-<right>` still walk
the panes there, and the window border, which says focus in every chat, is
true of the Shift chords as well as the Cmd ones.

## The code

- `scheme/packages/cua.scm` - the commands, the keys, the toggle.
- `apps/compos_core/priv/editor.scm` - the movement and editing states, `*editing-state-maps*`, and the global map the Emacs keys come from.
- `scheme/packages/cua-test.scm` - the selections, and the gate.
- `apps/compos_core/priv/tests/editing-state-test.scm` - the state itself.
- `docs/KEYMAPS.md` - the ladder. `docs/EDITING-SURFACE-SPEC.md` - the client half of the two states.
