---
name: code-editing
description: Edit source code in live compos buffers instead of the filesystem sandbox. Load before the first code edit.
---

# Edit code in compos buffers

Read the structure of a file first. `(code-outline "BUF")` gives one row
per definition as `(LINE KIND NAME DOC)` — DOC is the docstring, or the
first line when there is none. `(code-find "BUF" "text")` gives the rows
whose name or doc contains that text.

Then read exactly one definition with `(code-read "BUF" LINE)`, and
replace exactly one with `(code-replace! "BUF" LINE NEW)`. Use those four
for whole definitions — they address code by structure, so no string has
to match. Tree-sitter answers where the buffer has a grammar, and
indentation answers everywhere else, so read the result back after a
replace.

Below a definition, select and edit by expression. `(code-sexp "BUF"
"anchor")` returns the smallest expression that spans that unique text.
An optional LEVELS argument widens it by parents.
`(code-sexp-replace! "BUF" "anchor" NEW)` replaces it.

For a smaller change use `(buffer-replace! "BUF" OLD NEW)`,
`(buffer-replace-all! "BUF" OLD NEW)`, `(buffer-insert-before! "BUF"
ANCHOR TEXT)`, `(buffer-insert-after! "BUF" ANCHOR TEXT)` or
`(buffer-delete-text! "BUF" TEXT)`. Each of these takes text you have
read, never a byte offset, and each one reports what it did.

Every edit lands in the live buffer, so the change is attributed and the
open buffer stays true. Then save it: code you replaced in a file is not
done until the file holds it, and Elixir, JavaScript and any other
compiled source only reaches the running editor through a save.
Make the smallest edit that does the job, and keep the file's style.

Keep file and shell changes under `(default-directory)`. A workspace-id
means worktree-init isolated this task from the primary checkout.

The browser category is denied for coding work by default. Verify editor
UI through compos buffers, overlays, render state, components, and the
real key dispatcher. Do not use Chrome or tab-* calls. If every
editor-native approach fails and browser access is essential, explain
why and ask the user to enable `M-x browser-mode`. Do not ask before
then.
