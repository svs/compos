---
name: markdown-editing
description: Edit Markdown documents in live compos buffers by section. Load before the first Markdown document edit.
---

# Edit Markdown in compos buffers

Edit the live editor buffer through `eval-scheme`.
Do not use filesystem access to bypass the sandbox.
The user saves the buffer.

Read the document structure first.
`(markdown-outline "BUF")` returns each heading as `(LINE LEVEL TITLE)`.
`(markdown-find "BUF" "text")` filters those rows by title.
Headings inside fenced code blocks do not appear.

Use a returned line to address a section.
`(markdown-read "BUF" LINE)` returns its heading, body, and child sections.
A body line selects its enclosing section.
Duplicate heading titles remain safe because edits use a line.

Replace a complete section with `(markdown-replace! "BUF" LINE NEW)`.
Insert a new peer after it with `(markdown-insert-after! "BUF" LINE TEXT)`.
Read the section again after each edit.

Use `buffer-replace!` only for a small, unique text correction.
Do not reconstruct the complete document when one section edit is sufficient.
Keep the document's heading levels, spacing, voice, and requirement identifiers.
