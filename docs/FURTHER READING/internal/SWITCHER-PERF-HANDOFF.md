# Switcher performance: handoff

Written 2026-09-16. The work is not finished.

## 1. Status

The user opened C-x b after a full session of work on it and said: "and we
have gotten worse".

Nobody has measured that report. Measure it before you change any code. The
last number recorded in the editor's own stopwatch was refresh 355 inside a
total of about 400 ms, and the counted cost was 210,597 Scheme function
applications for one draw. Confirm both again. The machine carries concurrent
sessions and a compile, and identical work has swung by 2x between samples.

Do not trust a millisecond taken on a hidden probe buffer. See section 6.

## 2. What the user asked for, in order

1. C-x b is slow. group-move is slow.
2. 305 buffers are open. Agents must clean up the buffers they open quietly.
3. C-x C-b has the same problem and must be as fast as C-x b.
4. No motion effects anywhere in the editor, and none in a popup.
5. The buffer list must show HEAD like magit does: branch, or detached with
   the short sha.
6. The whole scheme is not making sense. It cannot cost so much to render 60
   lines. We are DoA if that is the case.
7. Can we make it a panel instead of a minibuffer? The answer was: do it.
   **This work never started.** An editor restart interrupted it. It is the
   largest open item.

## 3. The number that decides everything

The interpreter floor, measured directly:

    (car (list 1 2))                pure builtin        0.18 us
    (string-byte-length "abc")      string builtin      0.64 us
    (monotonic-ms)                  host call, no args  0.38 us
    (buffer-local B 'created-at)    editor API          1.70 us
    (f a b)                         Scheme function     1.90 us

That is about 630,000 Scheme calls per second. A 16 ms frame buys about 8,400
calls.

One C-x b makes 619,400 function applications to draw 60 lines. That is 10,300
per line. A line should cost tens of calls: read six cells, fit each, join,
emit spans. Sixty lines at 50 calls each is 3,000 calls, or 5.7 ms.

**The budget is under 100 Scheme calls per rendered line.** Work to the count,
not to the milliseconds. The count does not move with machine load.

Count a command with profile-start! before it and profile-stop after it. Read
bind_params! for Scheme calls and builtin_apply for builtin calls. apply_fn/3
is the sum of the two, exactly.

## 4. What landed

All of it is in the open jj change zkwmmmxu, except where a commit is named.
That change also holds a second session's edits to chat.scm, agent-fleet.scm,
buffer.ex, docs/WINDOWS.md and listing_window_test.exs. Those are not this
work.

### Per keystroke, not per draw

* dashboard--sync! left post-command-hook. The dashboard line is built when a
  window is filled with the buffer, through the group-display-dirty flag that
  already existed. A first attempt added a buffer-shown-hook handler as well;
  the switcher test caught it building the line twice, and it was removed.
  Commit e917fe65.
* dismiss-sync-visible! left post-command-hook. It was registered twice, and
  every real cause already has its own trigger. Commit e917fe65.
* Result: post-command! went from 39 to 42 ms down to 2.7 ms.

### The draw

* list-chip and ibuffer-total read a count that the source build leaves behind
  in *ibuffer-source-facts*. They no longer rebuild the source to say N of M.
  This was 69 ms per keystroke.
* ibuffer-meta-with counts rows. It no longer weighs them. The header said
  "238 buffers, 4 modified, 27.0M". The byte total and the modified count
  cannot be known without asking every buffer, so they were dropped on the
  user's instruction. It now says "238 buffers". This was 52 ms per keystroke.
* list-keep-sections read (list-opt buf 'section?) once per entry. One option
  read costs about 0.26 ms. It is read once per draw now. This was 90 ms per
  keystroke.
* list-active-layout checks its cache before it builds what the cache would
  have answered.
* ibuffer-name-fit and ibuffer-field-fit fold over the page, not over every
  row. A buffer you cannot see no longer sets the width of the column you can.
* Each row is laid out once. list-row-lines and list-composml-fields both
  called list-lay-out with the same cells and the same columns.
  list-prepare-rows! lays the row out once and both readings consume it.
* ibuffer-field-cell memoises per draw, beside the column widths. A draw asked
  for the same cell twice, and a chat's size is a stat of its log file.
* list-row-overlays builds the row context once and hands it down. Every row
  re-derived the key function and the marks local to answer "not marked".

Counted: 295,530 applications, then 228,848, then 210,597.

Measured: header per draw 126 ms down to 3 ms. Filter keystroke 360 to 790 ms
down to 125 to 160 ms.

### Elsewhere

* Motion. The breathing dot on a running chat is gone, in the C-x b table and
  in *chat-list*. Every animation and transition fallback is now zero, so a
  missing variable can only mean no motion. appearance--anim-apply! is on
  theme-change-hook, because theme-apply! clears every face attribute and the
  chrome.anim attribute was set imperatively: **loading a theme silently
  turned all motion back on**. Commit 7bf7753c.
* The HEAD line. git--head reads the branch, or detached with the short sha
  and the subject. diff--head-block draws it as the first line, and
  diff-refresh fetches it on its own schedule.
* M-x profile. It arms for the next command and reports where the command
  went. Commit d081c3f1. The call-site counters in profile.scm are not
  committed. They swap map, filter, fold, for-each and remove for counting
  wrappers; the wrappers recursed until another agent added
  *profile-site-busy*. Keep that flag.
* Buffer checkpoints. A checkpoint keeps auto-revert-base only for a buffer
  with unsaved work. 270 buffers held a base byte-identical to their text, and
  24 held 11.7 MB that matched nothing. auto-revert-woken! re-seeds the base
  from disk on wake, and only on agreement.
* The desktop globals fix. See section 7.

## 5. Every change, by jj change

Read the change description for the detail: jj show ID.

| change | commit | what |
| --- | --- | --- |
| lwnqyrlk | | git.scm: read the state of HEAD, answer it on the diff backend |
| vrrwxrnv | | diff-mode.scm: the view leads with HEAD, magit style |
| mpmwrwrl | | style the Head line |
| txlmkkun | | tagged block with its own class |
| ovwruxwr | | the test finds the Head line by class, not position |
| loluonuo | e917fe65 | no derived state per keystroke: the dashboard line at show time, dismiss sync off post-command-hook |
| lozlxsur | d081c3f1 | M-x profile arms the next command and reports where it went |
| pxuzuurl | 7bf7753c | nothing moves on its own: the breathing dot is gone, every motion fallback is zero, the setting survives a theme |
| zkwmmmxu | open | the buffer table stops weighing the workspace to draw a page of it; the desktop globals fix; the tests for both |

The open change zkwmmmxu also holds a second session's edits to chat.scm,
agent-fleet.scm, buffer.ex, docs/WINDOWS.md and listing_window_test.exs. Those
are not this work and the description does not claim them.

## 6. What is open

In the order a next agent should take them.

1. **The panel.** The user asked for the switcher to be a panel, not a
   minibuffer, and said to do it. Nothing was written. The user's own theory
   for the remaining cost is that the frame redraws the other buffers to make
   room for the minibuffer. Test that theory before you build.
2. **Pay per buffer you own.** ibuffer-rows builds the sectioned model for
   every buffer in scope, then the draw shows 60. That is 78,973 applications
   for rows that never reach the screen, about 0.57 ms per buffer. The model
   is a pure function of (buffer set, memberships, MRU order, current group)
   and the mode already declares a stamp. Cache against the stamp. Take the
   page from buffer-list-mru, which costs 1 ms for 640 buffers.
3. **1.8 ms per drawn row.** 60 rows cost about 110 ms: list-prepare-rows! 54,
   list-composml-text! 33, list-row-overlays 13 to 43, list-write! 18. A flat
   list does not fix this.
4. **buffer-local writes republish the whole locals map.** Buffer.publish/2
   puts the locals into the ETS row whole, so one local write copies every
   node: 192,122 nodes and 1.1 ms on the compos chat. The function beside it
   already refuses to flatten the rope and the overlay maps for the same
   reason. Give locals their own ETS table keyed by buffer and key, which also
   deletes the match spec in BufferView.local/2. The cheaper alternative, to
   skip the republish when only a local changed, leaves the cost where it is
   worst.
5. **The browser half.** Untouched. patch 30 ms for a 630-byte patch, present
   60 ms, and keys queue 63 to 90 ms behind each other. Scheme work does not
   fix this.
6. **pre-command! costs 34 ms.** Never examined.
7. **ibuffer.scm line 334** folds over four markers 723 times with no short
   circuit. Small, and free to fix.
8. **chat-wire-turns is 34 MB of the checkpoint store.** It is larger than the
   transcript text and it is not in desktop-skip-locals. Dropping it needs a
   decision: it is not known whether a restored chat needs the wire turns to
   resume a session.
9. **list? is not a builtin.** Two authors reached for it. Adding it beside
   pair? in apps/compos_scheme/lib/compos/scheme/builtins.ex is two lines. It
   needs a compile and a hot reload of the live daemon, so it was not done
   mid-session.

## 7. Landmines

Each of these produced a wrong conclusion in this session.

* **A hidden probe buffer lies.** A buffer that nothing displays answers
  buffer-local in 167 us where a real buffer answers in 2 us. A whole
  paragraph of per-call numbers was wrong because of this, including the claim
  that list-opt costs 100 ms of a draw. On a real buffer those 436 lookups
  cost a few ms. Totals from a probe track the real thing; the per-call
  numbers inside do not.
* **A probe is not a view.** C-x b is already a flat MRU list: ibuffer.scm
  near line 1579 opens the prompt with sort recent and grouping none. An
  unregistered probe falls back to ibuffer-default-grouping, which is group,
  and costs 267 ms more. A table built on that probe said grouping was the
  cost of C-x b. It is the cost of C-x C-b.
* **The generated fun name does not name a function.** Many builtins share
  one: the comparison, the sum and car all report the same generated name. The
  Elixir function table cannot attribute list work at all. That is why the
  call-site counter lives in Scheme.
* **Advising a list primitive from Scheme recurses.** The advice path itself
  runs through list primitives. Count inside the Elixir builtin, or use the
  profile-site-busy flag that profile.scm now has.
* **Tracing roughly doubles the cost.** A traced C-x b reported 709.8 ms; the
  same command untraced cost 399 ms.
* **The call counter cannot see inside a host primitive.** An ETS read or a
  checkpoint load is invisible to it. Counts are necessary, not sufficient.
* **Do not run a scheme test in the live daemon.** Running the ibuffer header
  test by hand left three zz-ib test buffers in the user's buffer list. Use
  the ExUnit wrapper, which runs an isolated daemon.
* **ibuffer_scheme_test.exs stops at the first failure.** Nothing after
  ibuffer-act-add-here-keeps-the-old-membership runs. To check a later test,
  write a throwaway wrapper .exs, run it, and delete it.

## 8. The desktop globals defect, fixed 2026-09-16

The editor logged that the globals did not install, with the reason: unbound
variable list?. It then came up with no groups, no layouts and no history.

install_globals puts the whole set back in one call. hidden-windows restores
first, and its lambda read (list? saved). This Scheme has null? and pair? and
has never had list?. The first of fourteen globals raised and the call died
with all fourteen inside it. groups.scm had the same call in group-mru.

1. (list? saved) became (pair? saved) in layouts.scm and groups.scm.
2. desktop-global! in editor.scm restores one key. desktop-globals! walks
   through it.
3. install_globals in desktop.ex still tries the batch. On a raise it puts the
   globals back one at a time and names the key that failed. A global that
   cannot restore itself now loses only itself.

Verified on the live daemon: all 14 globals round-trip without raising.

## 9. Test state

Passing: list_draw, list_page_scheme, list_performance, switcher_performance,
list_group_narrow, modeline_scheme_test, buffer_lifecycle_test, and the three
new tests below.

New:

* every-persisted-global-takes-back-what-it-gave in
  priv/tests/hot-reload-test.scm. Each restore reads the value its own state
  fn wrote. It raises when a broken global is registered, so it catches the
  class.
* a global whose restore raises does not take the others down, in
  test/compos/desktop_restore_test.exs.
* ibuffer-header-totals-come-off-the-source in priv/tests/ibuffer-test.scm.

Known failures, all present before this work:

* ibuffer-act-add-here-keeps-the-old-membership in ibuffer-test.scm.
* A row-order failure in ibuffer_prompt_scheme_test.exs.
* every literal mode-name write names a registered mode, in
  desktop_restore_test.exs. The aa-other-mode it names is in ibuffer-test.scm
  at HEAD.
* LLM configuration history survives desktop restore. The test expects a flat
  list; the code writes a plist. Neither file is in the working diff.
* Five failures in group_switch_command_test.exs, in the area the second
  session is editing. Not isolated against a clean tree.

Deleted: test/compos/profile_sites_test.exs. It tested Eval.tally_on and
tally_off, which do not exist. That design lost, because a check on the
builtin path costs every command forever.

## 10. This session (2026-09-16, later)

Landing on top of the open change, in the working copy.

### Landed

* **One pass over the scope.** `ibuffer-table-load!` now reads `context-only`
  in the same `buffer-read-many` and filters the snapshot with the
  `ibuffer-row?` rules, so `ibuffer-table-rows` opens from
  `ibuffer-scope-names` and never runs the per-buffer `ibuffer-source`
  filter. The eligible set is unchanged (verified 237 of 637).
  `ibuffer-workspace-path?` holds the workspace rule over a path already read.
* **The chat list sections from a snapshot.** `chat-list-table-load!` reads
  every chat fact in one `buffer-read-many`, and `chat-list-rows` sections by
  group, state, or model from it. `ibuffer-note-kinds!` and
  `ibuffer-group-buckets`'s per-row membership walk left the chat list's hot
  path. A chat's runtime status stays out of the snapshot: the default group
  view never reads it, and the state view asks it through the existing memo.
  `chats-list-test.scm` passes.

### Measured, and the honest number

The snapshot is a win, but a small one for chats, because the cost moved, it
did not vanish:

* `buffer-read-many` over 40 chats is ~23 ms. The same read over 637 plain
  buffers is 9 ms. Chat locals are expensive to read — the republish-the-whole-
  map cost in open item 4 is the real floor.
* `agent-status` (18 ms/40) and `chats-filesize` (27 ms/40) stay per row and
  unbatchable. The cells still read both, so the size and the status are
  asked in the loader AND in the draw.

So the next win is not the sectioning. It is open item 4 (give locals their
own ETS table), and then routing the drawn chat cells through the same
snapshot so a status and a size are asked once per draw.

### Still open, narrowed

* The chat-list cells still use `ibuffer-cells-for`, which reads a live buffer
  per row per field. Convert them to a `text-template` (as ibuffer-mode
  already did) so the draw reads the snapshot the loader built.
* `ibuffer_test.exs` has 8 failures about the column layout, the header, and
  the switcher-style heading. These are the ibuffer-mode presentation that the
  fast-picker change replaced, not this session's work. `ibuffer_picker_test`
  covers the new form and passes.
