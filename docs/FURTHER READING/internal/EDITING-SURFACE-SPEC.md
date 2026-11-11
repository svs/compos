# Editing surface: contenteditable as the input surface

Status: proposal, 2026-08-30. Prototype: `docs/examples/contenteditable-proto.html`
(open it over http, not file://, and type into it).

## The problem

The editor cannot reach Word-level fidelity because the browser's text-entry
stack never runs. The client listens to `keydown`, calls `preventDefault` on
every key, and sends a key name to the server (`app.js` `keySpec`). That
path drops everything the browser does for text:

- dead keys (`e.key === "Dead"` is dropped; Option is claimed as Meta, so
  Option-e e never produces an accent)
- input methods (`e.key === "Process"` is dropped: no CJK, no emoji picker)
- dictation, autocorrect, autocapitalize, spellcheck
- native selection: double-click word, triple-click line, drag, shift-click,
  touch, the native caret and its blink, RTL
- the accessibility tree and screen readers
- drag-and-drop of text and files
- rich clipboard (HTML, images) on paste and cut

The client then rebuilds a caret, a region, visual-line motion, and mouse
mapping by hand (cursor spans, region spans, the wrap map, `posIn`,
`settleCaret`). That code is the fidelity bug list.

This is a solved problem. Every serious web editor (ProseMirror, CodeMirror 6,
Lexical, Slate, Quill) uses one `contenteditable` element as the input surface
and keeps its own model as truth. The editor renders the DOM, the browser
provides text entry and selection, and `beforeinput` reports the user's intent
before the DOM changes. Google Docs is the exception (canvas) and pays for it
with a private IME and accessibility layer.

## The design

The server stays the editor. The client stays a view. What changes is the
event the client sends: intent, not key.

### Model (unchanged)

- Buffer text is truth. Point and mark are byte offsets.
- The server sends a window as keyed rows. A row is a list of runs
  `{s, text, face, display}`. `s` is the byte offset of the run's first
  visible character. Hidden markup (`**`, `#`, link targets) is not in any run.

### Surface

- The window body is one element with `contenteditable="true"`,
  `spellcheck="true"`. LiveView does not patch inside it (`phx-update="ignore"`).
  A small client function applies row payloads: replace changed rows by key,
  then restore the DOM selection from point and mark through `data-s`.
- A run with a `display` spec (image, widget, block) renders as a
  `contenteditable="false"` island. The browser treats it as one character:
  the caret jumps over it, Backspace deletes it as a unit, and the intent
  arrives with a target range that spans the island.

### Intent

`beforeinput` is the input event. The client maps the event's target range to
bytes with `data-s`, calls `preventDefault`, and sends
`{type, from, to, text}`:

| inputType | sent as |
|---|---|
| insertText, insertReplacementText (autocorrect) | replace from..to with text |
| insertParagraph, insertLineBreak | replace with "\n" |
| deleteContentBackward/Forward, deleteWordBackward/Forward, deleteSoftLineBackward, deleteByCut | replace with "" |
| insertFromPaste, insertFromDrop | replace with text; HTML rides along for rich paste |
| formatBold, formatItalic, formatUnderline | format intent on from..to |
| historyUndo, historyRedo | never fires (the browser's undo stack is empty); Cmd-Z is a chord |

Composition (IME, dead keys, dictation): when `isComposing` is true, do not
`preventDefault`. The browser owns the DOM of that one run until
`compositionend`. The client holds any row payload that arrives in between,
then sends one replace for the composed run and applies the held payload.

Chords still ride `keydown`: any key with Ctrl, Meta (from the CMD list), or
Alt, plus function keys, Escape, and Tab. Plain printable keys never reach
`keydown` handling.

### Selection

The native selection is the region. `selectionchange` sends point and mark.
Only native motion and pointer gestures authorize a selection report. Typing
and DOM patches cancel delayed reports. Each report carries the buffer text
version it measured; the server ignores reports for an older version, so a
late caret update cannot move point backward between successive insertions.
Mouse code (`posIn`, `mouse_sel`, `caretPositionFromPoint`) goes away.

Motion commands that need layout call the browser's own layout:
`Selection.modify(alter, direction, granularity)` with granularity
`character | word | line | lineboundary | paragraph | documentboundary`.
`next-line` in visual-line mode is `modify("move","forward","line")` on the
client followed by a `selectionchange`. The wrap map and its measurement pass
(`app.js`, `visual-row-move!`) go away.

Plain arrows, Home, End, Page keys, and Shift-arrows can be either native or
server commands. Proposal: native when `cua-mode` is on; server commands
otherwise. Both update the same point.

An editable surface has a movement state and an editing state. Neither is a
mode. The user lands on a window in the movement state: the four Cmd-arrows
travel as keys, so the focus chords move past the buffer. The
first key that is not ESC or C-g enters the editing state, where the browser
keeps Cmd-<left> and Cmd-<right> as line start and end. Cmd-<up> and
Cmd-<down> walk the group in every state. ESC
or C-g returns to the movement state; ESC runs `keyboard-quit`. A change of
the active window or of its buffer is a new landing. A read-only buffer stays
in the movement state.

The state lives in two places that agree. Scheme owns it for every buffer
(`editing-state-on!`, `editing-state-off!`, `editing-state?` in `editor.scm`):
the post-command hook enters the editing state after any command except
`keyboard-quit`, the window commands and the neutral commands. A window
command is a directional command or any command in the `windows` domain;
it leaves the state, as `keyboard-quit` does. The landing check also
leaves it, and the keymap `editing-state-map` is in force only in the editing
state. A neutral command is one a Shift chord runs (`editing-neutral-commands!`
in `editor.scm`, called by `cua.scm` and `groups.scm`): pressing S-<left> or
M-S-<left> says nothing about whether you are editing here, so it leaves the
state as it found it. The state installs the maps on `*editing-state-maps*`,
and `cua.scm` adds `cua-mode-map` to that list, so the Shift selections answer
in a buffer you are editing and a buffer you have just landed on keeps the
plain meaning of those chords: S-<left> walks buffer history, M-S-<left> moves
to the group on the left.

`editing-state-map` is the marker of the state and holds no binding.
The Cmd-arrows the state gives to the caret are on `editing-caret-map`,
and a mode can refuse a map of the state by name
(`editing-state-maps-off! MODE MAPS`). `chat-mode` refuses the caret map:
a chat is a conversation you type in without pause, so a chat that held the
Cmd-arrows while armed would never answer the window motion again. A chat
still arms `cua-mode-map`, so Shift there extends a region. A buffer the
server draws (the chat) is handled here alone. The client mirrors the state
for a contenteditable surface (`editingAfterKey` in `app.js`), because
the native-or-key decision for a Cmd-arrow must run inside `keydown`; a
Cmd-arrow the client keeps native never reaches the server map.

- A selection report (`sel`) is a caret motion in the selected window and nothing else. A click selects a window through `mouse` (window, line, column) before its caret is reported, so a `sel` for any other window is stray - the browser's selection lives in the last editable buffer, and a patch that nudges it (a popup opening, a scroll beside it) is not a move anyone made. The client reports only the active window's caret, and the server drops a report for another window.
- Each visible window shows its point. The active editable window uses the native caret. Inactive windows use a steady hollow marker.

### Pending operations

A key typed before the previous round trip returns must not read the DOM
caret, because the server has not moved it. The client keeps an optimistic
caret: after sending a replace, `caret = from + bytes(text)`. While ops are
unconfirmed, a collapsed intent uses that caret. The last reply places the
caret from the server's point. The prototype shows this works at CDP typing
speed (faster than any human) with an 8 ms simulated round trip.

### Policy (Scheme)

The primitive is one event; Scheme keys a handler per type with `(add-hook! (list 'input-intent TYPE) (lambda (from to text) ...))`.
Scheme maps intents to commands: `insertText` runs the same path as
`self-insert-command` (abbrev, electric pairs, hooks), `insertParagraph` runs
`newline`, `deleteContentBackward` runs `delete-backward-char` and decides
what Backspace at a hidden marker means, `formatBold` runs the mode's
emphasis toggle. The server keeps every command, keymap, hook, and mode.

## What this gives

- Accents, IME, dictation, autocorrect, spellcheck, emoji picker: from the
  browser, at zero cost.
- Native caret and selection: correct under wrap, in RTL, in proportional
  fonts, across islands.
- Embedding: an image, a table, a widget, an iframe is a run with a display
  spec and an island. Backspace, selection, and copy treat it as a unit.
- Rich paste: `insertFromPaste` carries `text/html`; the server converts to
  the buffer's format.
- Agents that type through CDP or the accessibility API reach the editor.
- Less code: cursor spans, region spans, wrap map, mouse mapping,
  `settleCaret`, the markdown iframe, the image caret placeholder all go.

## Known risks (from ProseMirror and CodeMirror 6)

1. Some browsers mutate the DOM despite `preventDefault` (Android IME, some
   Safari autocorrect paths). Mitigation: a `MutationObserver` fallback that
   reads the changed run back and sends the diff, the way ProseMirror's
   DOMObserver does. Chrome desktop honours `beforeinput`.
2. A row payload that lands mid-composition must be held, never applied.
3. Selection restore after a patch must be exact, or the caret jumps.
4. Tables inside `contenteditable` are poor in every browser. Keep a table
   as an island with its own editor until proven otherwise.
5. Dead keys and IME were not driven by automation (CDP has no input
   method). The claim rests on the editors above, not on a measurement here.

## Order

1. F1 (shipped 2026-08-30): contenteditable surface on the existing row
   renderer. `beforeinput` intents (`KeyDispatch.handle_intent/4`,
   `input-intent!` in `editor.scm`), composition hold through
   `phx-update="ignore"`, chords on keydown, the server caret kept and the
   native caret hidden. A collapsed intent acts at point, so no optimistic
   caret is needed; only a ranged intent carries bytes. Paste stays on the
   `paste` event. Not yet: native caret and selection as the region,
   `Selection.modify` motion, islands.
2. F2 (shipped 2026-08-30): the browser draws the caret and the
   selection while the surface owns the keyboard; `sel` reports point and
   mark as bytes (a motion keeps the mark, a click clears it);
   `client-select!` asks `Selection.modify` for visual-line motion on an
   editable surface. A fresh wrap map still answers first (a rendered page
   measures one), so the map code stays until the markdown iframe goes.
3. F3 (shipped 2026-08-30): `markdown-mode` (packages/markdown-mode.scm)
   paints markers with `md-marker`, hidden by CSS on every line but the
   cursor's; headings take a size from the theme; `![alt](path)` draws as an
   `<img>` island (local paths through LocalImage), a bare X status URL as
   an oembed card island. An island is `contenteditable=false` with
   `data-len`, so the caret treats it as one character and the client's
   byte mapping walks over it. Not yet: row-level block styles (quote, list
   marker, code block chrome) and tables.
4. F4: HTML files edited in place: tree-sitter-html gives byte positions, so
   an HTML document renders as itself with `data-s` on every text node.
5. F5: rich paste (HTML to the buffer's format), file and image drop.
6. F6 (shipped 2026-08-30): the mode split. `morg-mode` owns structure
   (folds, narrowing, babel, TODO) and enables `markdown-mode` and
   `writing-mode`; `markdown-mode` owns the faces and the islands;
   `writing-mode` owns typography and the prose keys; `cua-mode`
   (packages/cua.scm) owns the Shift selections (`cua-select-*`, bound
   globally by `M-x cua-mode`, and in writing buffers by writing-mode).
   Not yet: C-c/C-x/C-v acting on an active region, and `preview-mode`
   as rendered rows rather than the iframe.
7. F7 (shipped 2026-08-30): the goal column counts graphemes and a jump
   resets it; one command is one undo step (`Buffer.undo_group/2` around
   `KeyDispatch.run/1`); `kill-buffer` asks before it drops edits to a
   file; a failed Loro call drops the mirror for that buffer instead of
   letting the next call panic inside the NIF.

8. F8 (shipped 2026-08-30): the browser owns caret motion on an editable
   surface. Arrows, Home, End, Page keys, with or without Shift, stay with
   the browser; `selectionchange` reports the caret as bytes; the server
   never re-places a caret that already stands where it says. A collapsed
   delete (Backspace, Delete, word and line deletes) acts at the server's
   point, never at the DOM caret, which is one patch behind while typing.
   An overlay change repaints the views that show the buffer, so a face
   painted from the reactor (morg, markdown) covers the last typed letter.
   `morg-mode` is the plain source mode again; `markdown-mode` is opt-in.

9. F9 (shipped 2026-08-30): the modes, as the user stated them.
   `preview-mode` on a Markdown file draws the page in place on the
   editable rows: the preview typography, heading sizes, markup stepped
   back off the cursor line, inline pictures, X cards, the native caret
   (renderer "rows"; the iframe stays for `.org`, `.txt`, HTML and apps).
   Without preview the file is the plain source in the editor font.
   `morg-mode` is the Markdown major mode: folding, narrowing, babel,
   TODO, plain faces. `writing-mode` is measure and layout. There is no
   `markdown-mode`; packages/markdown-mode.scm is preview's painter
   (`markdown-paint-on!`/`markdown-paint-off!`). The rows save the look
   they replace and restore it when they go. A headless buffer (no client
   has reported a caret) keeps the server's own visual-line motion.

Still open after F1-F9: F4 (HTML files edited as themselves), F5 (rich
paste), C-c/C-x/C-v on an active
region in `cua-mode`, and the wrap-map code that the markdown iframe
still needs. The Markdown painter now draws row-level block styles (quote, code,
fence, rule) and tables.

## Implemented text redisplay

The line renderer selects the viewport before preparing display segments.
It reads source lines from the immutable rope in the render snapshot.
The preparation bound is three window heights plus eight logical lines.
A buffer that fits this bound retains native scrolling. Larger buffers use
the existing server viewport. Folding and narrowing apply before selection.

The window cache retains segments for its displayed rows. Keys contain line
text and relative face, overlay, and chrome ranges. An edit above a row changes
its absolute byte offset, but does not invalidate its segments. Changed overlays
invalidate the affected rows. Cache entries outside the next viewport expire.
The `[:compos, :ui, :text_display]` event reports visible, prepared, and reused
row counts, with buffer name and text version.

Fontification does not run inside redisplay. The renderer requests faces for
the visible byte range and can display text immediately. Existing faces are
rebased through insertions and deletions and remain visible as provisional
faces until the new result arrives. Their version stays old, so they cannot
suppress a fresh request. This avoids a plain-text flash on every keystroke.
A buffer coalesces requests for 25 milliseconds and runs one supervised task
at a time.
The task uses a fork of the incremental syntax tree. Its parser has a separate
lock, so parsing cannot hold the edit path's parser lock. Queries cover only
the requested range, but parsing retains full document context.

Results name their text version and parser resource. The buffer discards
worker results after an intervening edit or language change. It publishes
accepted faces before sending a display notification. This notification is not a text
change and does not invoke text-change rules. Up to eight recent display ranges
are cached per buffer. Text and version always come from the same snapshot.

This change does not replace the input or selection protocol. The editor
still serializes commands and owns point. Snapshot text materialization and
fold geometry can still involve the whole buffer; this bound applies to line
preparation, face queries, and the line DOM, not every operation in redisplay.

Native vertical motion stays within the rendered text until it reaches a
slice boundary. At that boundary the client sends a versioned motion request;
the buffer crosses the source-line boundary and recenters the cursor. Moving
past the viewport edge places point halfway down the next screen, clamped at
the beginning and end of the file. Wrapped rows inside the slice still use
the browser's layout, and Shift-selection retains its anchor across the edge.
