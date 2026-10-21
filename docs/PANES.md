# Panes: the window model

The frame is a row of panes. A pane has a share of the width and a stack of
windows; the first window is on screen. A window has a stable key, a mode and
a stack of buffers; the first buffer is shown. A group owns one such layout
per frame. That is the whole model, and it is one plain value:

```scheme
(panes   ((id "p1" share 1 windows ("w1" "w3"))
          (id "p2" share 1 windows ("w2")))
 windows ((key "w1" win 4  mode "scheme-mode" buffers ("b.scm" "a.scm") preferred #t)
          (key "w2" win 7  mode "chat-mode"   buffers ("*chat*")       preferred #t)
          (key "w3" win #f mode "dired-mode"  buffers ("*dired*")      preferred #t))
 next-pane 3 next-window 4 capacity 3)
```

`win` is the renderer's window id. It attaches while the window is on screen
and is stripped when the value is saved. The key is the identity. This is the
model docs/WINDOWS-SPEC.md describes; the code is `scheme/packages/panes.scm`.

## Three layers

1. **The model** (`panes.scm`) is pure. Every function takes a layout and
   answers a new one: `panes-open`, `panes-show`, `panes-pop`,
   `panes-drop-buffer`, `panes-move-window`, `panes-move-buffer`,
   `panes-consolidate`, `panes-rename`, `panes-validate`. Its tests are
   `panes-test.scm`, and they run with no frame.
2. **The policy** decides where a buffer opens. `(define-window-policy! NAME
   DOC PLACE)` registers one; PLACE takes the layout, the buffer and a
   context and answers `(window KEY)`, `(new-window PANE)` or `(new-pane)`.
   The custom `window-policy` picks one. Two ship:
   - `mode-affinity`: the window that holds the buffer, else the preferred
     window of its mode, else a new pane while the layout is under capacity,
     else a new window in the selected pane. A display takes the least
     recently used other pane.
   - `emacs`: a visit takes the selected window; a display reuses the window
     that shows the buffer, pops a pane while there is room, else takes the
     least recently used other window.
3. **The applier** (`panes-mode.scm`) lays the frame out as the model says,
   with one call: `window-arrange-line!` over the top windows and the pane
   shares. Every other window waits behind its pane, hidden in the core,
   with its point and history. The doors go through the model while
   `panes-mode` is on: a visit, a display, `q`, a kill, a rename, a group
   switch. A change made by another door is read back into the model.

## Window ids

A window id is immutable. The core mints one when a window is made and never
hands it to another window while that one lives. A saved layout, the value
`window-tree` answers, names the id of every leaf, on screen and hidden, and
`window-tree-set!` gives each window back under that id when no other window
holds it. Only a leaf without an id, or whose id another frame took, matches
an old pane by buffer, and only then does the core mint. The desktop file
carries the ids too, so a restart gives every window back under the id the
layouts and groups knew it by. The group switcher's look and its return
therefore leave every id as it found it, and a record keyed by window id,
pane rows, restore records, the hidden ring, stays true across a restore.
The tests are `window_ids_test.exs`.
## The board

`M-x list-panes` shows the model as a list: each pane, its windows (on
screen or behind), each window's buffers. `RET` goes there, the arrows move
a window or a pane, `k` closes a window or takes a buffer out of one, `K`
kills, `c` gives every mode one window, `+` `-` `=` set the shares. The board
is `panes-board.scm`. It reads the frame when the mode is off, so it is a
true picture either way.

## Layout history

`M-x layout-undo` puts back the previous pane arrangement and `M-x
layout-redo` goes forward again. Winner restores whole configurations,
buffers and points included; this keeps only the layout: the panes, their
shares and the order of their windows. A window both states hold keeps the
buffers it shows now, so what you were reading stays and only the shape of
the frame moves. A change of buffer alone records no state; a change of
shape does, and ends any redo. One history per frame and group, fifty
states deep, in `panes-history.scm`. It needs panes-mode on.

## Status

- `M-x panes-mode` turns the model on. It is off by default.
- While it is on, the layout target, the window ring and group-panes stand
  down for placement. They still exist in window.scm and groups.scm.
- Not done yet: saving the layout with the group record across restarts,
  the Expose spread drawn from the model, and retiring the old mechanisms.
