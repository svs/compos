# Popups

A popup is one window that floats over the frame: a listing, the messages, the telemetry, a shell. It stays an ordinary window in the tree, so every window command reaches it; its class takes its split out of the flow.

## Rules

1. The default side is the right edge, on every frame. A display rule can name another side (`(add-display-rule! NAME 'popup '(side bottom size 0.4))`).
2. In the popup, `M-<left>`, `M-<right>`, `M-<up>`, and `M-<down>` move it to that edge (`popup-move-left` and friends). The keys are the popup's, not the buffer's: they go in when the buffer floats and out when it stops floating, and the buffer's mode then gives it its own `M-<arrows>` back.
3. The side a buffer was moved to is the side it opens on next (`popup-side` local); a rule's side still wins.
4. The popup shows one buffer at a time, and a buffer shown over another keeps it underneath (popper's stack). Dismissing the top one — `q` in a listing, `C-t` on the telemetry — brings back the one under it; dismissing the last closes the popup. `C-\`` closes the whole popup and empties the stack. A peek never waits on the stack (replaced, it is killed), and the stack holds live buffers only: it is pruned on every write.
8. A buffer floats only in the popup window. The class that floats it is a buffer-local, so `popup-show-on` un-floats the buffer it replaces, and a buffer shown in any window but the popup's is an ordinary buffer again, whatever class it carried. A buffer that kept the class floated in every window it was shown in after.
9. A floating popup is always the second window in the tree, whatever its side: the class places it, and the window it covers keeps its id and its place. `popup-bufferize` swaps it into first place when it becomes a real window on the left or the top.
10. A quiet popup is transparent to the point. `popup-show-quietly` sets the popup window's buffer in place and moves the selection nowhere (a new popup is split, filled, and the selection put back in one step); nothing that manages point or focus sees the popup: `other-window` and windmove pass it by, a selection report from another window is dropped, a kill never fills a window with it, and un-floating a peek runs no mode setup. A peek shows that way. `popup-show-on` selects the popup; a listing you open to work in uses it.
11. `M-<down>` and `M-<up>` outside the popup scroll it (`scroll-other-window` reads the popup beside your work before the next window); `scroll-popup` and `scroll-popup-down` scroll it by name.
5. `C-\`` toggles the popup (closed, it shows the last popup buffer again); `C-M-\`` (`popup-bufferize`) makes it an ordinary window in the place it occupies; `C-c p` puts any buffer in the popup; `q` in a listing dismisses it (rule 4).
6. A popup is a visit, not a place: it says nothing about the frame's group (docs/groups.md).
7. `*Messages*`, `*Telemetry*`, `*ibuffer*`, `*shell*`, `*llm*`, and `*opencode…` are popups by rule.
