# Peek

A peek is a look at a buffer without keeping it. `RET` on a row in dired or the switcher peeks. The rules live in `priv/editor.scm` (the peek section) and here.

## Rules

1. A peek shows in the popup, always, on the side away from the window it was asked from: it never covers the listing. A peek takes no focus: it is shown by setting the popup window's buffer in place, the selection moves nowhere, and `other-window` and windmove pass its window by (`M-<down>` scrolls it; `RET` on its row opens it, and only then is it a window you can enter). A peek is a look, and the popup is where a look goes; the windows stay as they are. A popup buffer of its own (the messages) waits under the peek and comes back when the peek goes.
2. One peek at a time. The next peek replaces the last one. A buffer that a peek made is killed when it is replaced; a buffer that existed before the peek is only shown, never killed.
3. A peek is read-only. `peek-mode` is a minor mode: its setup makes the buffer read-only and records the state it had; keep puts that state back. The mode is saved with the buffer, so a peek on screen at a restart comes back as a peek.
4. Open is `RET` again on the row, or `M-RET` (`peek-open!`): the mark goes, the popup gives the buffer up, and the selected window shows it as a visit would. `M-x keep-buffer` keeps without opening; a change from outside the keyboard (an agent's edit) keeps too.
5. `q` on the peek dismisses it (the read-only keymap binds it). `q` anywhere else (`quit-window`) dismisses a peek that shows before it does anything else: in dired, ibuffer, or any listing, the first `q` takes the peek and the next one the listing. A dismissed peek leaves a row in recent; the switcher lists recent below the live buffers and hides live peeks.
6. Browse keeps its own chord: `M-RET` on a link peeks it, and `M-RET` on the same link keeps it.
7. In dired the popup opens on `RET` only. While a peek shows, the highlight drives it: rest on a file (`dired-peek-ms`, 120 ms) and the popup shows that file instead, and `RET` on it opens. A rest fires only if the reader is still in the listing. With no peek showing, moving the highlight shows nothing. `dired-peek-on-move` turns the following off. A peek opens the file quietly (`visit-quietly`): the selected window never shows it on the way to the popup.
8. `M-<down>` and `M-<up>` from the listing scroll the peek: `scroll-other-window` reads a peek on screen before the next window.

Tests: `priv/tests/peek-test.scm`, `priv/tests/peek-md-test.scm`, run by `test/compos/peek_test.exs` in the test daemon (they rearrange windows).
