# Popups

A popup is an ordinary buffer in an ordinary window. The model is popper.el from Emacs. `scheme/packages/popper.scm` holds all of it. There is no popup window kind.

## Which buffers are popups

`popper-reference-buffers` is a custom list. Each entry names popups:

- A string is a regexp on the buffer name, for example `"\\*Messages\\*"`.
- A symbol is a major mode, for example `help-mode`. A derived mode matches too.
- A procedure takes the buffer name and answers true or false.

The list is empty by default, so no buffer is a popup until you name it. `popper-toggle-type` overrides the list for one buffer. It writes the buffer-local `popper-popup-status`: `popup` or `raised`.

A buffer with a leading space and a float are never popups. Each of them has its own window.

## Where a popup shows

A display of a popup goes through `display-buffer`. popper.scm adds one display rule. The rule has a procedure as its pattern, and the procedure answers true for a popup. The rule's action is `popper-bottom`:

1. A window that shows the popup already takes it.
2. Else the window of the latest popup on screen takes it. The new popup covers the old one.
3. Else the frame's root splits, and a new window along the popup's edge of the frame takes it. The edge is the buffer-local `popper-side` (set by the move commands), else the custom `popper-side`, `"bottom"` by default. The window gets the buffer-local `popper-size`, else one third of the frame.

The popup window then has the selection, as in popper. It is an ordinary window with normal focus. Every window command reaches it.

A row preview is not a popper display. It takes the preview rule, as any other look does.

The layout does not tile a popup window. `window-work-buffer?` answers false for a popup, so the layout target does not count it and a display of another buffer does not take it.

## The commands

| Command | Key | What it does |
|---|---|---|
| `popper-toggle` | none (M-x) | Closes the popup on screen. With no popup on screen, it shows the latest popup again. |
| `popper-cycle` | `` M-` `` | Shows another popup in the popup window. It shows the popup used least recently, so each press reaches a different popup. With no popup on screen, it shows the latest popup. |
| `popper-move-left`, `-right`, `-up`, `-down` | `C-M-<arrow>` | Moves the popup on screen to that edge of the frame. The buffer keeps the edge for its next display. The focus stays where it was. |
| `popper-toggle-type` | `` C-M-` `` | Makes the current popup an ordinary buffer: its popup window closes, and the display chain shows it in a work window. Makes any other buffer a popup: its window shows the buffer it showed before, and the buffer shows at the bottom. |

The keys are the keys that the popper README suggests, except `` C-` ``. That key runs `group-next-mode-buffer`, so `popper-toggle` has no key.

`group-next-buffer` walks every buffer of the group. Cmd-down runs it, and Cmd-up runs `group-previous-buffer`.

## Closing a popup

A close is the quit-window restore. It reads the `restore` record on the window's leaf:

1. When the popup covered another buffer, the window shows that buffer again. When that buffer is a popup too, that popup comes back, and the window keeps the record that a popup display made it. The next close deletes the window.
2. When a popup display made the window, the window goes. The last window of a frame never goes.
3. With no record, the window shows the last buffer of its history that is not a popup (Emacs `switch-to-prev-buffer`). With no such buffer, the window goes when another window is left.

A close never kills the popup buffer. The latest popup is the first popup in the buffer ring (`popper-buffers`), so `popper-toggle` can show it again.

## The float is not a popup

A float is a window whose buffer wears the float class (window.scm, "the float"). Two surfaces float: the card of a row preview (`preview-show ... 'float`) and a prompt's table in the panel or the modal shape. The float is a preview surface, not a popup. The class string keeps its stylesheet name, `popup popup-SIDE`.

## What went

The earlier model floated a popup over the frame as a side window. The side window, the popup's own buffer stack, the return arrangement, the popup focus code, the move keys (`popup-move-*`), `popup-toggle`, `popup-buffer` (`C-c p`), and `popup-bufferize` are gone.
