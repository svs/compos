# buffer-log-mode

Every edit in compos carries provenance (`:user`, `:editor`, `:process`, or `{:agent, id}`). `buffer-log-mode` displays every accepted revision of a buffer so you can inspect who wrote each line and when.

## Open

- `C-x v l` or `M-x buffer-log` from any buffer.

## Keys

| Key | What it does |
| --- | --- |
| `n` / `p` | Step through revisions and preview each revision beside the log |
| `RET` | Visit the selected revision in full (`revision-mode`) |
| `C-c v` | Toggle the side-by-side detail preview |
| `g` | Redraw the revision list |
| `q` | Quit |

The header displays the recording state, active policy, and accepted head hash. Each save closes a changeset and writes a checkpoint.

See also: [code-mode](code-mode.md), [PROVENANCE](../FURTHER%20READING/PROVENANCE.md).
