# Peek

A peek shows a buffer to look at, without keeping it. `RET` on a row in dired or the switcher peeks; `RET` again keeps. The rules live in `priv/editor.scm` (the peek section) and here.

## Rules

1. One peek at a time. The next peek replaces the last one. A buffer that a peek made is killed when it is replaced; a buffer that existed before the peek is only shown, never killed.
2. Where a peek goes, in order: the window the last peek used; a window that shows a peek; the window a popup covers, when the peek is asked from the popup; the other window. With no other window the peek opens in the popup. A peek never splits the frame.
3. Keep is one buffer-local going away: `RET` again on the row, an edit, or `M-x keep-buffer`. A kept buffer keeps its window.
4. `q` on a peek drops it and puts the layout back: the popup is dismissed, a split closes, a lone window falls to the next buffer. A dropped peek leaves a row in recent; the switcher lists recent below the live buffers and hides live peeks.
5. The wire. The page draws a line from the window the peek was asked from — from its current row — to the near edge of the window that shows the peek. The peek buffer carries `peek-from`, the source window's id; the leaf renders it as `data-peek-from`, and the client draws an SVG curve over everything, touching nothing. Keep, replace, and drop remove it. It is not saved: a restart has no wire.

Tests: `priv/tests/peek-test.scm`, `priv/tests/peek-wire-test.scm`, run by `test/compos/peek_test.exs` in the test daemon (they rearrange windows).
