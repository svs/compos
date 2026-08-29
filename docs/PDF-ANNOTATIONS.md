# Annotating PDFs - design note

Status: design, 2026-08-29. Nothing here is built.

The reader shows a PDF page as a PNG inside generated HTML. The buffer text
is a projection, not the document. So a PDF note cannot anchor to a buffer
offset, and `annotate.scm` cannot paint it as an overlay range.

The task is not "add notes to pdf.scm". The task is to make the annotation
layer accept a second kind of location. A PDF is the first client. An image,
a video frame, and a spreadsheet cell are the next ones.

## What exists

- `annotate.scm` owns the model: an annotation is a plist in the source
  buffer's `annotations` local. The store is one file per document, under
  the project or under `<aimax-home>/annotations/`. `find-file-hook` turns
  the mode on when a store exists.
- The projections are the overlay paint, the `*annotations*` list, the
  margin cards, and the echo line. All read the same list.
- `pdf.scm` owns the reader. `*pdf-layout-json*` gives every page its text
  blocks, and every line its bbox in PDF points, top-left origin.
  `pdf-find-text` already reads that layout. `pdf-page-geometry` gives the
  page size and its rotation.
- A rendered page reaches Scheme through one channel: an `aimax:VERB/ARG`
  link. The href limit is 2000 bytes. The preview iframe runs no scripts.

## The anchor

A PDF annotation adds three keys to the plist:

    page   1-based page number
    rect   (X Y W H) in PDF points, top-left origin
    match  the quoted line text

`match` is the durable anchor. `page` and `rect` are the last known
position. A relocate runs `pdf-find-text` on `match` and writes the page and
the rect back. A note whose text is gone becomes `state "orphan"`. It stays
in the list and it stays in the file.

This is the same contract the text sources use. There, `match` is the
annotated text and `line` is the last known line.

## The seams to add to annotate.scm

`annotate.scm` assumes one kind of source: a text buffer with lines. Five
small functions carry that assumption. Each becomes a seam that a mode
supplies, with today's behaviour as the default.

1. `annotate-document-path BUF` - which file the store belongs to. The
   default is the buffer name. A `pdf-edit-mode` buffer answers with
   `pdf-original-path`, so a generated copy shares the original's notes.
2. `annotate-locate BUF A` - where the annotation is now. The text default
   searches the buffer text. The PDF version calls `pdf-find-text`.
3. `annotate-place-label A` - how to name the place. The text default is
   `L12`. The PDF version is `p3`. The list, the margin, and the echo line
   all read this.
4. `annotate-goto BUF A` - how to move there. The text default moves point.
   The PDF version sets the page and selects the note.
5. `annotate-paint BUF` - how to draw. The text default sets overlay ranges.
   The PDF version re-renders the page.

Register them per major mode, the way a mode registers a context provider:

    (annotate-source! "pdf-reader-mode"
      'path pdf--annotate-path 'locate pdf--annotate-locate ...)

## Drawing the note on the page

`pdf--document-html` grows one layer above the page image. For every
annotation on the current page it emits one box:

    <a class="ann note" style="left:12.4%;top:31.0%;width:64.2%;height:1.9%"
       href="aimax:pdf/note-a7"><span>7</span></a>

The coordinates are percentages of the page size in points. A percentage
needs no recompute when the zoom changes, and it survives the dark page
filter. The severity supplies the colour, from the `ann-*` faces the
annotate layer already declares.

A click on the box sends `aimax:pdf/note-a7`. The existing
`on-preview-link!` handler selects that note, echoes it, and shows the
margin card.

## Making a note

Two gestures, neither one needs new client JS.

**Click a line.** The same layer emits one transparent link per text line
of the page, under the note boxes:

    <a class="ann-target" style="..." href="aimax:pdf/annotate-3-17"></a>

The argument is the page and the line index. Scheme reads the line text out
of the layout, prompts in the minibuffer, and stores the note. This is the
primary gesture, and it costs nothing but the layout read the reader
already does.

**Name the text.** `C-c ! a` prompts for the text to annotate, then for the
note. `pdf-find-text` supplies the page and the rect. This is the keyboard
path, and it is the path an agent uses.

## What stays unchanged

- The store. A PDF note is a plist in the same file format.
- The `*annotations*` list, its tabs, and its verbs.
- The margin cards, resolve, dismiss, and reply.
- The survival rule. The notes live on disk. `pdf-reader-setup!` loads them,
  so a page change, a hot reload, and a restart all rebuild the same boxes.

## Phases

1. The five seams in `annotate.scm`, with the text defaults. No behaviour
   changes. The existing annotate tests prove it.
2. `pdf.scm` registers the PDF source: the store path, the locator, the
   page label, and the goto.
3. The page HTML draws the note boxes and the click targets. The
   `pdf-annotate` command. Tests assert the box coordinates against a
   stubbed layout, through the `*pdf-layout-json*` seam.
4. The margin, the list, and `M-n` / `M-p` over a PDF.
5. Later, and separate: export the notes into a copy of the PDF as real
   PDF annotations, so other readers see them. This goes through
   `pdf-edit-mode`, which already writes a generated copy and never touches
   the original. It needs one new mechanism, a PDF annotation writer.

## Landmines

- A rotated page. `pdf-page-geometry` returns the rotation. The rect must
  turn with it before it becomes a percentage.
- The 2000 byte href limit. The argument carries an id, never a payload.
- The page text `<details>` block and the note boxes both change the buffer
  text on every render. `pdf--replace!` marks the buffer saved, so the
  churn stays out of the modified flag.
- A note on a page the layout cannot read, such as a scan with no text
  layer. `match` is then empty, and only the rect anchors the note. Say so
  in the list: the note reads "page only".
