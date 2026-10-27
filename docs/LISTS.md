# Lists

The list mode in `scheme/packages/tabulated-list.scm` draws every table in the editor: ibuffer, dired, the switcher, feeds, sentry, the telemetry. A mode says what its columns are and what one row puts in them. The mechanism lays out, pads, colours, pages, narrows, and draws. This document holds the rules the mechanism keeps.

## One draw

1. A draw reads the mode once. The row context (`list-row-ctx`) carries the mark column, the column lines, the mode's `cells`, `row-cells`, `render`, and `key` fns, and the marks. Every row reads the context. No row calls `list-opt` or reads a buffer-local: a buffer-local read is a call into the buffer's process (0.16 ms), and a row that asked ten times cost 6 ms.
2. The header is computed once per draw and passed down with its line count. Each displayed row computes its cells and text lines once; semantic records reuse both. Selection overlays use the saved row offsets, so cursor movement never recomputes cells.
3. The chip (the narrowing and its count) is computed only while the list is narrowed. Counting asks the mode about every row.
   The key bar (the mode's `'footer` keys) is the `ui/keys-bar` card at the bottom corner of the window. It shows the main keys and `? all N`; `?` (`list-keys-toggle`) grows it into the whole keymap.
4. A draw is few buffer changes: one `buffer-replace-range!` of the whole text, one `buffer-set-locals!` for the offsets, the head count, the row height, the width, and the stamp, one overlay set, one goto. Every change is a frame refresh and a render. A delete and then an append let a render between them see an empty buffer, reset the window's top, and write it back; the view jumped. `list_draw_test.exs` holds a redraw at eight changes or fewer.
5. Numbers that hold this: 400 rows draw in about 330 ms and 60 rows in about 150 ms, on a laptop, with faces on every cell.

## Pages

1. A mode with many rows declares `'page-size N`. The draw writes the first page. The entries keep every row, so the counts, the filters, and the marks see them all. The drawn rows are a prefix of the entries, so an index names the same row in both.
2. `n` on the last drawn row and PgDn (`scroll-up-command`, remapped in every table to `list-page-down`) draw the page they land on first, so a screen never ends in the key bar with rows to come. `(list-more! BUF)` draws the next page.
3. The meta line says "N of M shown, PgDn draws more" while rows remain.
4. An open shows the first page again. The pages you drew were for the last visit.
5. Wheel scroll does not draw pages: the server owns scrolling, and a scroll runs no command.

## Order

1. A list with `'local-filter` fetches its rows on an open and on `g`, and a mark, a flag, or a narrowing redraws the rows it has. A source in MRU order changes under a row's preview; a table that refetched on every mark moved the row under the cursor.
2. `SPC` marks the row at point in every markable list mode. `/` narrows the rows to what you type — it is the search key everywhere in this editor, so it is the search key in every list. `<` cycles the declared grouping mechanisms and `>` the declared sorting ones; grouping and sorting are a pair and read as one. These keys are reserved by every list mode. A list without the corresponding declaration reports that it has none.
3. `ibuffer` sections its rows by group, by mode, or by directory. Under the group sectioning the frame's group comes first, then the other groups by name, then the ungrouped rows. Inside a section the rows sort by name, by recency (MRU), or by size; the defaults are `ibuffer-default-grouping` and `ibuffer-default-sorting-mode`.
4. A folded section (`ibuffer-toggle-filter-group`) is one heading row that carries the member count, the modified count, and the bytes. It is not a separator: the narrowing keeps it while a member matches, the highlight can rest on it, and RET opens it. The meta line counts folded members.
5. A right-aligned last column pads on its left, so its text ends at the column's edge; its face span starts after the padding.
6. The key bar shows only the main keys that the mode declares, and ends in `? all N`, where `?` shows every key. The card floats over the rows, so it does not push the rows down.
7. A mode's `'meta` answers a string, or `(TEXT SPANS)` with its own faces. The ibuffer wide head says the grouping and the sort as chips this way, the current one lit.
## Trees

1. A list is a tree when its mode names `'parent`, `(lambda (buf row))` that answers the key of the row's parent, or `#f`. After every filter and every order, a row whose parent is listed in the same section follows that parent, one step deeper. A row whose parent is not listed (filtered out, or in another section) stays where it sorts, as a root. A separator or a `'section?` row ends a section.
2. `'nest-cell N` names the cell of the row's first line that takes the indent: `└ ` at depth 1, two spaces more for each step deeper. `(list-row-depth BUF ROW)` gives the depth, and `(list-nest-prefix BUF ROW)` gives the text the cell starts with, for a mode that measures its own columns or places its own faces.
3. `'nest-flat? (lambda (buf))` keeps the order as it is: a child wears the indent in its own place and is not moved. The ibuffer activity order uses it.
4. `TAB` (`list-toggle-children`) folds the rows under the row at point; on a child it folds the child's parent. `S-TAB` (`list-toggle-all-children`) folds every parent, or opens them all when one is folded. A folded row says how many rows it hides: `▸ +11`. `(list-row-hidden BUF ROW)` answers `#f` for a row with no children, else that count (0 when open). The folds are the buffer's own (`'list-folded-rows`) and outlive a refresh.
5. The todo list nests a sub-task under its task (the task's `parent`). ibuffer nests a buffer under its kind's `'parent`, else its dismissal parent: the chat list puts a spawned chat under the chat that spawned it. In ibuffer, `TAB` on a row with children folds them, and on any other row folds the section.

## Point

1. The point belongs to the reader. No process moves it: a draw restores the row by its key, a preview card opening or closing over the listing moves nothing (docs/POPUPS.md rule 10), an open of a list you already have keeps the row you left it on. A narrowing lands on the first row because the old row may be gone; that is the reader's own act.
2. Remembering is enough. Dired: a listing opened for the first time starts on its first entry; opened again, it is where you left it. `^` and `RET` on `..` open the parent listing where it was — the row you left it on is the directory you went into, so nothing needs computing.

## Narrowing

1. `f` narrows on every keystroke; `\` widens by one. The filters stack and persist with the buffer; an open clears the typed query and keeps the mode's own kinds.
2. Repeating an unchanged query does nothing. `(list-set-query! BUF QUERY #t)` changes the query and fetches its source in one draw. C-x c uses this only when crossing between the recent and full chat scopes; later keys reuse the source. Closing a disposable prompt clears the query without redrawing a table that is about to be killed.
3. A mode's own filter kinds (`'filter (buf entry f)`) ride the same stack. The telemetry's `t`, `k`, and `s` are such kinds, and the same key again widens.
4. A list defines filters. `'filters` is a list of `(PREFIX FIELD DOC)`, FIELD `(buf entry) -> text`. In the `/` filter a word that starts with a prefix, `s:open`, keeps the rows whose field holds the rest; the other words match the row as before, and every word must hit. `(list-define-filter! MODE PREFIX FIELD DOC)` adds a filter to any list mode at runtime, and `(list-mode-filters MODE)` lists them. A list without filters keeps its matcher unchanged.
## The telemetry list

1. `C-t` shows `*Telemetry*` in the popup, on the right (docs/POPUPS.md). `C-t` on it dismisses it: a popup buffer under it comes back, else the popup closes.
2. Two views by measured width: under 100 columns the time, the layer, the job, the bar, and the number; from 100 columns the owner, the wait, and the trace too. RET shows every field in either.
3. A layer wears one colour. The bar beside a duration is on one scale: a full bar is the slow threshold. The meta line shows p50, p95, a sparkline of the newest 24 keystroke round trips (oldest on the left), and the last key with its time.
4. The list follows the work the user causes. The collector sends Scheme one notice per burst of rows, once a second at most, and never waits. Scheme redraws only while the list shows and only when a row the user caused arrived since the last draw: a keystroke or an intent (a traced row) or a Scheme job. The list's own refresh leaves live rows, browser rows, and a lane job named after the package; those are not causes, so a quiet editor draws nothing.
5. The editor's own untraced `refresh` and `render` rows are hidden by default. Every buffer change makes one pair, and they say nothing a traced row does not. `a` shows them; the meta line says "quiet" while they are hidden.
6. 60 rows a page; 400 events retained in the view.

## Chat previews

C-x C-c and C-x c share the chat list. Row navigation updates selection immediately; the preview waits for 150 ms of idle time (`chat-list-preview-delay-ms`). Both paths use the same per-frame debounce. Leaving cancels the pending request, and callbacks recheck the selected row and preview window before loading it. Timer bookkeeping stays outside display state.

### Chat filtering

Typing updates the minibuffer without rebuilding the table on the key handler. Table updates coalesce over 60 ms; transcript search starts after 150 ms idle in a cancellable Scheme task. New input cancels the old task, and callbacks check the request generation and actual minibuffer input before publishing results. RET and row navigation apply pending table filtering before choosing a row. C-g closes the entry while retaining the typed query and results; `\` pops the filter. This is the shared list-filter contract, including ibuffer. Pending redraws cannot reset selection after navigation.

While a chat search filter is active, results use Title matches, Metadata matches, and Transcript matches sections, in that order. Each chat appears only in its highest-priority matching section; empty sections are omitted. These count-bearing headings replace normal group separators during search and are skipped by row navigation. Closing the entry keeps the sections. Metadata matching includes title, summary, model, state and slug. Queries of at least three characters also search live chat text and dormant chat logs without waking chats. Transcript matching is a case-insensitive literal substring, with a snippet displayed on matching rows.

Ibuffer and chat lists reuse the previous candidate set when a substring query grows, and reuse prepared cells across query changes. Backspace, replacement queries and refresh use the source snapshot again. Transcript completion invalidates candidate reuse so newly found rows can appear. These caches are bounded and kept outside display state.

Group folding edits the cached section heading and toggles its already-sorted members. It does not fetch the source or recompute group statistics. The redraw reuses prepared cells for unchanged rows when the layout context still matches.

Ibuffer and ichat bind `C-x n n` to the group at point and `C-x n w` to all groups. Group scope is stored in the persistent buffer-local `ibuffer-narrow-group` as its section key and label. It filters the cached source before the text query, so widening retains that query and folding/refresh preserve the scope. Regrouping clears it. List modes can provide `source-filter (buf source)` to restrict a source snapshot before ordinary matching.

Ibuffer also coalesces filter redraws over 60 ms while input updates immediately. A complete mode name such as `chat-mode` matches that exact major mode; ordinary text remains a substring search across name, title, mode and metadata. Filtered group counts and membership describe the matching subset, while the source retains all rows for widening and unfolding.

Chat preview copies retain the rich renderer's block ranges and input boundary from live sources. Saved transcript files are projected into user/status/prose blocks without restoring chat identity or a runtime. Preview buffers enable the source major mode and stay read-only. Source render projections are preserved for rich modes; list modes skip refetching during preview setup. Switching modes clears the old chat rendering locals.

Ibuffer's searchable marginalia includes the row title/name, mode, path, kind metadata, size and age. It excludes transcript hits from chat-list. Search data is cached per source snapshot (up to 16 views, 2048 rows each); changing the query reuses it and refreshing the source invalidates it. Chat-list adds transcript snippets through its own matcher.

The minibuffer picker also defers its table draw by 60 ms and flushes before selection. Ibuffer previews wait 150 ms and validate the row and query again before loading a buffer, so typing and navigation do not synchronously initialize a preview on every key.

## Fast buffer picker

`ibuffer-prompt-pretty` and `ibuffer` use the same ibuffer table renderer.
The prompt uses a minibuffer dock; the management command uses an ordinary window. It loads
metadata with one `buffer-read-many` call, then groups, filters, and formats
that snapshot. Each visible row is formatted once. Text and CSS field ranges
come from that same result. Opening a picker does not weigh chat logs.

Both forms share three `defcustom`s in the `buffers` group:

| Setting | Default | Meaning |
| --- | --- | --- |
| `ibuffer-info` | `#t` | Show mode, group membership, and `*` for unsaved files. |
| `ibuffer-pretty` | `#t` | Align and fit the Name, Mode, and Group columns. |
| `ibuffer-group-by` | `'group` | Group by `group`, `mode`, `directory`, or `none`. |

Group sections use group names. The current group leads; other groups follow
by name. Rows retain recency within each section. `M-g` cycles grouping for
the open picker. `C-c i` toggles Info and `C-c p` toggles Pretty without loading
the source again. The Pretty toggle reports server redraw milliseconds in
the echo area; it does not include browser patch or paint time.
Use `customize-save!` to persist a setting.

`(ibuffer-format ROW INFO? [GROUP?])` describes fields from the loaded snapshot.
`ROW` is `(NAME TITLE MODE GROUP MODIFIED PATH GROUP-ID SIZE)`.
It returns `(TEXT CLASS WIDTH TRIM PREFIX)` field specifications. Buffer columns
have compact fixed widths, so a delayed dock measurement or filtering cannot
stretch the name column across the screen. Group labels resolve registered
name icons using the same name format as the group rail. That projection is
cached across refreshes, and invalidated by group records, name format, or icon
registry changes; loading rows and grouping them share it.

Any list can supply `text-template` (buffer, row), or `prepare-template`
(buffer) returning that callback with context captured once per draw, and
`pretty` (boolean or
buffer callback). The shared list renderer fits and pads those fields when
Pretty is enabled, computes UTF-8 ranges once per row, and reuses that result
for text and semantic rendering. Both plain and pretty templates use direct
semantic rows; Pretty only controls fitting and presentation, not DOM nesting. `list-format-template` exposes the same pure
formatter for headers. The classes are `ibuffer-name`, `ibuffer-info`,
`ibuffer-mode`, `ibuffer-size`, `ibuffer-file`, `ibuffer-group`, and `ibuffer-modified`.
The pretty view uses section bands and a selection accent. Size and file columns
come from the existing bulk snapshot; group names appear in section headings
and also in a column when grouping by something else. Section counts come from the snapshot, without new buffer reads.
Pretty off skips the rich header, Size/File formatting, and section counts.
Metadata uses existing `f-dim`, `f-warn`, `f-accent`, and `f-bold` theme classes;
selection uses the standard `hl-line` styling.

A `composml-record` callback can also return `relative-fields` for text it
already formatted. Existing column-based lists keep their field path.

`M-x ibuffer` (also `C-x C-b`) opens a buffer with group headings and
metadata, using the plain presentation. `M-x ibuffer-pretty` opens that
management buffer with the pretty presentation. `C-x b` stays in the normal
minibuffer.
`C-x b` (`ibuffer-prompt`) opens the normal minibuffer completion list of
filenames, with no table buffer, dock or semantic row rendering. Selection previews in the invoking window;
cancel restores it, and buffers woken only for preview are put back to sleep.
`ibuffer-info` adds native completion hints for mode, group, and unsaved status
from the same bulk read; hints are also searchable. With Info off it reads only
the path needed for eligibility and displays names alone.
Duplicate filenames use full paths to distinguish them.
`M-x ibuffer-prompt-pretty` opens the richer docked table explicitly. `ibuffer-prompt!` accepts these options after its shape argument.

The management buffer uses the original responsive table renderer and keymap:
narrow below 64 columns, compact below 100, wide otherwise. The key hint bar
fits the available width. Names use the theme's fixed-pitch face; group labels
use its fixed-pitch and bold faces, keeping the calculated line widths valid.
The management key hints wrap at the window width, including `C-c v` for
previews on/off and `M-↓/↑` for group navigation. The preview toggle is a
chord on purpose: `p` walks rows in every list, and binding the toggle there
switched previews off for anyone who pressed `p` to go up a line. The reusable `ui/keymap` component gives keys
small theme-colored keycaps and labels in the theme's proportional font.
`footer-line-blocks` carries the component through the normal block renderer;
it is rebuilt on redraw/restore and cleared on a mode change.

`(mode-dismissible! "ibuffer-mode")` explicitly declares dismissal support,
independent of `special-mode` and the name of the quit command. Derived modes
inherit the declaration. `dismiss-mode` supplies child-first dismissal and the
corner `q`, then delegates to the mode's own quit action. Prompt surfaces remain
excluded. The normal `C-x b` picker is unchanged.

Preview copies read `buffer-text` for live and sleeping buffers alike. That reads
the saved checkpoint without waking the source, including generated dired and
detail views. A preview copies presentation data without running the source mode
setup; HTML details render in an inert, sandboxed document.

When the selected preview target is already visible in this frame, its existing
window gets the preview border instead of a duplicate card. The highlight is
window-specific, preserves focus and editing, and clears when the preview changes
or is dismissed. Hidden targets still use floating cards.

List previews reuse their normal ComposML projection. When transient blocks or
field ranges were discarded during sleep, the shared list renderer rebuilds
them from saved entries into the preview copy. It does not run mode setup or
fetch rows. Text tables retain their saved width and semantic fields.
