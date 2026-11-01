# Peek: a list row in a real window

A peek shows the buffer of the list row at point in a real window of
the panes model (docs/PANES.md). It replaces the floating card as the
default preview. The card stays as a choice.

## The setting

`listing-preview-style` is `peek` (the default) or `float`.

- `peek`: the real buffer in a window of the model, as this file says.
- `float`: the floating card with its read-only copy, as before.

One entry, `listing-preview!`, reads the setting and calls
`listing-peek!` or the card. The debounce, the tracking, `q` and the
dismiss go through the same entry, so a list does not know the style.
The switch for each list (`ibuffer-toggle-preview`,
`chat-list-preview`) turns off both styles.

## The model

A peek is a window in the model with a `peek` mark. It is not a frame
window of its own kind and it is not a float.

- Show: the peek window goes to the front of a pane's stack.
- Dismiss: the peek window goes. The window under it comes back to the
  front. Nothing is restored, because nothing under it changed.
- Keep: the mark goes. The window is a normal window.

There is one peek for each frame. The next row changes the buffer of
the same peek window. It does not add a window.

A layout that is saved (desktop, group switch, layout history) never
holds a peek window or a temporary pane.

## Which pane

The owner is the pane of the list window.

1. A pane after the owner: the peek goes there.
2. Else, when the layout is under capacity: a temporary pane after the
   owner. Dismiss removes it. A pane that the peek did not make is
   never removed.
3. Else a pane before the owner.
4. Else (one pane, no room): the peek goes over the list, in the
   owner's own pane.

This is the rule of `panes-display-beside!`, plus step 4. A peek and a
keep land in the same pane.

Prompts (`C-x b`, find-file): the list is the minibuffer, so it is in
no pane. The peek goes over the home window, the window the prompt was
called from, where the answer goes. `C-g` dismisses it.

If the row's buffer is already the front of a visible window, there is
no peek. The current peek, if there is one, goes.

## Keys

A minor mode, `peek-mode`, is on in the peek window while it is a peek:

| Key | Action |
|---|---|
| `q`, `C-g` | Dismiss. The list comes back to the front, point on the same row. |
| `n`, `p` | Peek the next or the previous row of the list, in place. |
| `RET` | Keep. |

The keys work in every peek, over the list or beside it. While the
peek is up, they hide the same keys of the buffer under them.

In the list, the list keys stay. `q` in the list dismisses the peek
first. A second `q` quits the list.

## Lifecycle

| Event | Result |
|---|---|
| Next row | The same peek window shows the new row. The rule below applies to the row it leaves. |
| `RET` in the peek, or an edit in it | Keep. |
| `q`, `C-g` | Dismiss. |
| The list is killed, or leaves the front of its window | Dismiss. |
| The focus goes to a window that is not the list and not the peek | Dismiss. |
| The focus goes into the peek | Nothing. Moving focus does not keep. |
| A command acts on the peek as a window (move, display another buffer in its pane) | Keep. |
| `C-x 1` from the list | Dismiss. |
| `C-x 0` or `pane-remove` on the peek | Dismiss. |
| The list pane moves | Nothing. The peek holds a pane id, not a position. |

## The buffer

What happens to the row's buffer depends on what it was before the peek:

| Before | Dismiss | Keep |
|---|---|---|
| Asleep | Back to sleep | Stays awake |
| Awake | Stays awake | Stays awake |
| Not open (the peek opened it) | Killed | Stays open |

- Dismiss removes the peek window first, then puts the buffer to
  sleep: `buffer-sleep!` refuses a buffer on screen.
- A refused sleep (busy, pinned, on screen elsewhere) leaves the
  buffer awake.
- `preview-max-file-size` stays: a bigger file is not opened, and the
  echo area says its size.

## Code

- `panes.scm`: the `peek` mark on a window and on a pane; pure.
- `peek.scm`: `listing-peek!`, `peek-dismiss!`, `peek-keep!`,
  `peek-mode`, the pane rule and the buffer rule.
- `ibuffer.scm`: `listing-preview!` and its dismiss read
  `listing-preview-style`.
