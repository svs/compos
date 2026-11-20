# prog-mode, tree-edit-mode, lsp-mode, and occur-ts-mode

`prog-mode` is the parent of every language mode (`scheme-mode`, `elixir-mode`, `heex-mode`, `rust-mode`, `python-mode`, `go-mode`, `js-mode`, `c-mode`, `ruby-mode`, `sh-mode`, `html-mode`, `css-mode`, `json-mode`). Put shared bindings in `prog-mode-map` and shared setup in `prog-mode-hook`.

## Common coding keys

| Key or command | What it does |
| --- | --- |
| `C-M-f` / `C-M-b` | Move forward or backward over one balanced syntax form |
| `M-g i` or `s-i` (`imenu`) | Jump to any definition in the buffer |
| `M-.` (`goto-thing-at-point`) | Jump to definition (via LSP or source search) or follow link |
| `M-x ts-install-grammar` | Install a tree-sitter grammar for highlighting, folding, and outlines |
| `M-x compile` / `M-x next-error` | Run builds asynchronously and step through compiler errors |

## Structural browsing (`M-x code-browse`)

Walks the tree-sitter parse tree without changing the buffer's major mode: `h` (parent), `l` (first child), `j`/`k` (siblings), `Tab` (fold/unfold), `M-.` (goto definition), `RET` or `q` (exit).

## Structural editing (`tree-edit-mode`)

Selects and moves whole tree-sitter nodes (also works on Markdown buffers):

| Key | What it does |
| --- | --- |
| `<left>` / `<right>` | Select previous or next sibling node |
| `M-<left>` / `M-<right>` | Select parent / first child |
| `s-<left>` / `s-<right>` | Swap node with previous or next sibling |
| `s-<up>` / `s-<down>` | Lift node out of parent / move into next node |
| `C-x n s` / `C-x n w` | Narrow to selected node / widen |

## `lsp-mode` and `occur-ts-mode`

- `lsp-mode` connects a language server for goto-definition, `lsp-diagnostics-mode`, and `lsp-references-mode`.
- `occur-ts-mode` (`M-s t`) runs a tree-sitter query across a buffer and lists every capture with live previews (`RET` visits, `/` narrows, `g` re-runs).

See also: [code-mode](code-mode.md), [buffer-log-mode](buffer-log-mode.md), [05. CODE](../05.%20CODE.md).
