# Problem: visual-line motion decides in the browser

A task for an agent with a fresh context. Read `ARCHITECTURE.md` and
`BEAM-POWER.md` (the section "The client measures. Scheme decides.") first.

## The goal

Move every visual-line decision out of JavaScript and into Scheme, by having
the client report **where rows begin** instead of **what keys mean**.

## Why

`visual-line-mode` moves the caret by the row a reader sees rather than by the
source line. Where prose wraps depends on font metrics, measured width, kerning
and zoom, so the browser is the only place that knows it. That part is true and
stays true.

The mistake is what crosses the wire. The client currently sends decisions, not
measurements. Five routines in `apps/aimax_ui/lib/aimax/ui/layouts.ex` each work
out what a key MEANS by firing pixel probes at the DOM:

| routine | asked to answer |
|---|---|
| `visualLineMove` | which row is one above or below |
| `visualLineEdge` | where this row starts and ends |
| `exactSpot` | which source byte a caret sits on (uses `data-s`, correct) |
| `sourceSpot` | the same, by counting rendered characters (wrong: see below) |
| `previewSpot` | the same again, by matching text |

None of them can be tested. The file has no coverage, and
`.agents/skills/code-change/SKILL.md` forbids driving ai-max through a browser
to get some. Deciding that `End` means "end of visual row" is policy, and the
one rule of this repository puts policy in Scheme.

## Evidence

One session, 2026-08-28, produced these. Each lived in a different routine, and
each was found only by a person pressing a key and reporting what happened:

1. **Stale goal column.** `visualLineEdge` answers Cmd-Right and returns, so the
   `visualGoal.x = null` at the foot of the key handler never runs. The next
   Down probes at the x of wherever the reader was vertically before, and the
   caret lands mid-row. Still present; not fixed.
2. **Selection could not extend.** `visualLineMove`'s raw branch read
   `if (!cursor || extend) return false`, because its transport was the `mouse`
   event and the server cleared the mark unconditionally. S-Down therefore fell
   through to the server and selected by SOURCE line: one keypress swallowed a
   whole paragraph. **Fixed** by making the mark a parameter of the move.
3. **No raw branch at all.** `visualLineEdge` only ever looked for the preview
   iframe, so in a morg-mode source buffer Cmd-Right ran `move-end-of-line` and
   jumped to the end of the paragraph. Attempted four times by pixel probing and
   **reverted**; see the landmines.
4. **Rendered characters counted into a byte offset.** `sourceSpot` returns
   `span.toString().length` and `preview-goto-src!` adds it to a source byte
   (`preview.scm`, `(min (+ at off) ...)`). On a line with markup those counts
   differ, so the caret lands short. `exactSpot` avoids this with `data-s` and
   is the model to follow; `sourceSpot` is its unfixed predecessor.

## The design

The client already reports measured geometry on every patch:
`Editor.set_total_rows/2`, `set_window_rows/2`, `set_window_cols/2`. Add one
more of exactly that kind.

**The wrap map**: for each visible window, the byte offsets at which each
visual row begins. One list of integers per window, bounded by the rows on
screen. Derived from `Range.getClientRects()`, re-sent on the same trigger that
re-sends the row count.

Motion then becomes Scheme over data:

```scheme
(visual-row-start POS)          ; the offset the row containing POS begins at
(visual-row-end POS)            ; the offset it ends at
(visual-row-next POS GOAL-COL)  ; the offset one row down, holding the column
```

and the rules become `deftest`s in `priv/tests/`:

- a horizontal move ends a run of vertical moves, so it clears the goal column
- a vertical move keeps the goal column across a run
- a move to the row edge lands on the row the caret is on, never the one below
- extending keeps the anchor; not extending clears the mark

## Acceptance

1. `Cmd-<left>`, `Cmd-<right>`, `<home>`, `<end>` land on the visual row edge in
   BOTH a morg-mode source buffer and a rendered preview.
2. Their shifted forms do the same and extend the selection.
3. `<up>`, `<down>` and their shifted forms hold the goal column across a run of
   presses, and a horizontal move between them resets it.
4. Every rule above is a Scheme test that runs under `mix test`.
5. `visualLineEdge`, `sourceSpot` and `previewSpot` are deleted. `exactSpot` may
   stay as the byte resolver for clicks.
6. No behaviour regresses in a plain (non-visual-line) buffer.

## Landmines

Found the hard way. Do not rediscover them.

- **A window is not either/or.** A preview window matches BOTH
  `.buf[data-visual-lines='true']` and `iframe[data-rm='markdown']`: the preview
  draws in the iframe while the buffer element stays in the page. A branch that
  tests the raw selector first will answer for previews too.
- **A collapsed `Range` at a wrap boundary measures zero height** and reports the
  top of the NEXT row. The same character index is both "end of row N" and
  "start of row N+1". Measure with one character inside the range, or a row-edge
  move walks off the row.
- **The line-number gutter is inside the window box.** A probe that starts at the
  window's left edge lands in `.linenum`, and `posIn` answers column 0 of the
  source line. Bound scans to `.line-content`.
- **A single pixel probe rounds to the nearer side of a glyph**, so it is off by
  one either way. This is the deepest reason the probing approach fails: there
  is no single x that reliably names a row's first column.
- **`Desktop.init` sends itself `:restore`.** Do not restart Session-adjacent
  processes casually while testing; see `BEAM-POWER.md`.
- **Never hot-reload a speculative edit into a daemon someone is testing in.**
  The Hotload watcher lands every save immediately. Restart on a committed tree
  and say so, and have them hard-reload the tab: a normal reload keeps old JS.

## Out of scope

- The `Aimax.Core.BufferView` read model. Done, and unrelated.
- The Earmark raise guard in `earmark_ast/1`. Done, and unrelated.
- Fixes (1) and (2) above, already landed: the `mouse` event carries `extend`,
  and `visualLineMove` no longer refuses to extend. Build on them.

## How to verify

The suite is the only automated signal, and Scheme tests are the point of the
exercise: write them first. A browser check needs a person, so batch the
questions and ask once. Boot a daemon with `.claude/skills/aimax-boot` on its
own home and port, restart it on a committed tree before each round, and use
its verification step: prove the config landed, not just that the port opened.
