# Display buffer

Where a buffer goes when a command shows it. The mechanism is Emacs' `display-buffer`, in Scheme, in the display-buffer section of `priv/editor.scm`.

## The three verbs

1. `switch-to-buffer!` shows a buffer in the selected window. `find-file` and the switcher use it: a visit takes the window you are in.
2. `display-buffer` shows a buffer somewhere else and selects nothing. A result, a listing, a help page, a shell take their window through it. It returns the window.
3. `pop-to-buffer` is `display-buffer` and then a `select-window!`. A listing you open to work in uses it (`list-mode-show!`).

## The chain

`display-buffer` tries a list of actions in order and stops at the first that answers with a window:

1. the rule for the name in `*display-buffer-alist*`;
2. `*display-buffer-base-action*`, the user's list, empty by default;
3. `*display-buffer-fallback-action*`: `reuse-window`, `pop-up-window`, `use-some-window`, `same-window`.

The actions:

| action | what it does |
| --- | --- |
| `reuse-window` | a window that shows the buffer already |
| `pop-up-window` | split the largest work window when it is big enough (`split-window-sensibly`), else the selected one |
| `use-some-window` | another work window; the popup and a peek are not one |
| `same-window` | the selected window (`same` is the same action) |
| `popup` | the side window (`popup-show`, docs/POPUPS.md) |

`define-display-action!` adds one. An action is a function of the name and the alist that returns a window or `#f`.

## Splitting

`split-window-sensibly` is Emacs' rule: a window with `split-height-threshold` rows (80) splits below; else a window with `split-width-threshold` columns (160) splits beside; else the sole work window splits below whatever its size. Two windows side by side on a laptop meet neither threshold, so the next display takes the other window instead of making a third. Both thresholds are `defcustom`s in the `windows` group.

## Rules

`(add-display-rule! PATTERN ACTION [PARAMS])` puts a rule in front. PATTERN is a substring of the buffer name, or `(category KIND)` for a kind of display the caller names in the alist. ACTION is one action name or a list of them. A rule's actions come before the base action and the fallback, so a rule that names `popup` always lands in the popup, and a rule that names `same-window` never splits.

The callers pass an alist, a plist:

- `'category KIND`: the kind of display. A peek passes `preview`. The stock rule `((category preview) popup)` is last in the alist, so a rule for a name wins over it.
- `'inhibit-same-window #t`: keep the selected window out of the chain. `display-buffer-other-window!` is `display-buffer` with this set.

## Previews are a rule

A peek (docs/PEEK.md) is a display of category `preview`. By the stock rule it goes to the popup: dired and the browser show a file beside the listing without keeping it, and the windows stay as they are. To preview through the window chain instead, in `init.scm`:

```scheme
(add-display-rule! '(category preview) 'pop-up-window)
```

Then a peek takes a window the chain makes, the next peek takes that same window, and dismissing the peek removes the window. Point stays in the listing either way.

## quit-window

A display notes what it did to a window: `window` when it made the window, `other` when it took a window that showed another buffer. `q` (`quit-window`) undoes that first, then kills the listing: the window the display made goes, or the buffer the display replaced comes back. `window-quit-restore!` does the undo alone.

Tests: `priv/tests/display-buffer-test.scm`, run by `test/compos/display_buffer_test.exs` in the test daemon (they rearrange windows).
