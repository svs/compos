# Panes: the window model

The panes model is the only window system. The frame is a row of panes. A
pane has a share of the width and a stack of windows; the first window is on
screen. A window has a key, a mode and a stack of buffers; the first buffer
is shown. A group owns one such layout per frame. That is the whole model,
and it is one plain value:

```scheme
(panes   ((id "p1" share 1 windows (1701 1703))
          (id "p2" share 1 windows (1702)))
 windows ((key 1701 mode "scheme-mode" buffers (ID ID) preferred #t)
          (key 1702 mode "chat-mode"   buffers (ID)    preferred #t)
          (key 1703 mode "dired-mode"  buffers (ID)    preferred #t))
 layout two-chat capacity 3 focus "p1" next-pane 3)
```

The key of a window is its frame window id. The model mints it with
`window-id-new!`, and the draw makes a frame window with that id. A stack
holds buffer ids, not names, so a rename changes nothing.

The screen is a projection of the value. A command changes the value and
calls `panes-apply!`; the draw shows it. The focus is data too: the draw
always ends on the front window of the focused pane.

## Three layers

1. **The model** (`panes.scm`) is pure. Every function takes a layout and
   answers a new one: `panes-show-buffer`, `panes-show`, `panes-pop`,
   `panes-drop-buffer`, `panes-move-window`, `panes-move-buffer`,
   `panes-swap-windows`, `panes-consolidate`, `panes-set-layout`,
   `panes-validate`. Its tests are `panes-test.scm`; they run with no frame
   (`panes-key-source` #f gives keys w1, w2, ...).
2. **The layouts** (`define-layout!`) give the shape: how many panes, and
   the share of each. They are single, two-pane, halves, columns, two-chat
   and free. The model of a group names its layout in `layout`. `C-x l`
   chooses one and shows each as you move to it.
3. **The applier** (`panes-mode.scm`) lays the frame out as the model says,
   with one call: `window-arrange-line!` over the top windows and the
   shares. Every other window waits hidden behind its pane, with its point
   and history. A hidden window that no model holds is deleted after each
   draw.

## The doors

Every way to change the windows is a model edit:

- a visit (`switch-to-buffer`) and a display (`display-buffer`,
  `pop-to-buffer`). Only a display rule whose action places a buffer off the
  panes (the float, the dock, the selected window, a popup) runs that action.
- a detail of a list (`display-buffer-detail!`) opens in the pane beside the
  list (`panes-display-beside!`), never on top of it.
- `C-x 0`, `C-x 1`, `C-x 2` and `C-x 3`, `q`, a kill, a group switch.
- the motion: focus, window shift and swap, buffer move, eat.
- `select-window!` and `window-set-buffer!` outside a draw write the model
  first.

## Where the model is kept

- Per frame and group: frame-local `panes-layouts`. The desktop saves it.
- Per group: the group record holds the newest layout of the group, from
  any frame (`group-layout`). A frame that enters a group it never showed
  takes that layout. A group with neither gets a default layout of its
  members.
- An arrangement (a transient frame such as the windows map), a register
  (`C-x r w`) and the slides keep a model and draw it back.

## Layout history

`M-x layout-undo` (`C-c <left>`, winner) puts back the previous pane
arrangement and `M-x layout-redo` (`C-c <right>`) goes forward again. A
window both states hold keeps the buffers it shows now, so only the shape of
the frame moves. A change of buffer alone records no state; a change of
shape does, and ends any redo. One history per frame and group, fifty states
deep, in `panes-history.scm`.
