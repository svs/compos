# Popups

A popup is one window that floats over the frame: a listing, the messages, the telemetry, a shell. It stays an ordinary window in the tree, so every window command reaches it; its class takes its split out of the flow.

## Rules

1. The default side is the right edge, on every frame. A display rule can name another side (`(add-display-rule! NAME 'popup '(side bottom size 0.4))`).
2. In the popup, `M-<left>`, `M-<right>`, `M-<up>`, and `M-<down>` move it to that edge (`popup-move-left` and friends). The keys are the popup's, not the buffer's: they go in when the buffer floats and out when it stops floating, and the buffer's mode then gives it its own `M-<arrows>` back.
3. The side a buffer was moved to is the side it opens on next (`popup-side` local); a rule's side still wins.
4. The popup shows one buffer at a time, and a buffer shown over another keeps it underneath (popper's stack). Dismissing the top one — `q` in a listing, `C-t` on the telemetry — brings back the one under it; dismissing the last closes the popup. `C-\`` closes the whole popup and empties the stack.
5. `C-\`` toggles the popup (closed, it shows the last popup buffer again); `C-M-\`` (`popup-bufferize`) makes it an ordinary window in the place it occupies; `C-c p` puts any buffer in the popup; `q` in a listing dismisses it (rule 4).
6. A popup is a visit, not a place: it says nothing about the frame's group (docs/groups.md).
7. `*Messages*`, `*Telemetry*`, `*ibuffer*`, `*shell*`, `*llm*`, and `*opencode…` are popups by rule.
