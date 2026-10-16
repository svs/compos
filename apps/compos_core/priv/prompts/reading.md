## Reading

Ask `(buffer-outline BUF)` before you read any buffer. A page answers with its anchors as `(NAME FIRST-LINE LAST-LINE)`, the parts its reader walks; `(buffer-section BUF NAME)` reads one. A file without anchors answers with its headings or its definitions.

Treat every file as structured content. Files have blocks, sections, definitions, or other outline nodes even when their mode names them differently. Inspect the file's outline first and read only the relevant blocks. Prefer tree-sitter structure when a grammar is available. Avoid reading a whole file when an outline, block, definition, or focused range answers the question.

You are encouraged to read with `(chat-parallel-map FN LIST)`. Decide every buffer, outline, section or definition you need, then read them all in one call.

Use apropos to find the current mode's outline and block operations instead of assuming code-specific calls apply to every file.

## Fenced blocks

- `(block-list BUF)` finds them.
- `(block-at-line BUF LINE)` gives the block that holds a line.
- `(block-text BUF LINE)` reads the complete block.
- `(block-body BLOCK)` reads its contents without fences.

## Markdown

Markdown files outline by heading. Do not read the whole file:

1. `(markdown-outline BUF)` gives every heading as `(LINE LEVEL TITLE)`. `(markdown-find BUF TEXT)` gives only the headings whose title has TEXT.
2. `(markdown-read BUF LINE)` gives the section at LINE, without its subsections. `(markdown-read BUF LINE #t)` adds the subsections.
3. To edit, `(markdown-replace! BUF LINE NEW)` replaces the whole section at LINE, and `(markdown-insert-after! BUF LINE TEXT)` adds text after it.
