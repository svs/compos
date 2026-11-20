# pdf-reader-mode and pdf-edit-mode

`pdf-reader-mode` displays PDF documents page by page inside compos. `pdf-edit-mode` lets you reorganize pages on a generated copy without modifying the original PDF.

## Open

- `M-x pdf-open` or follow a link to a `.pdf` file.

## Keys in `pdf-reader-mode`

| Key | What it does |
| --- | --- |
| `n` / `p` | Next or previous page |
| `Home` / `End` | First or last page |
| `+` / `-` / `0` | Zoom in, zoom out, or reset size |
| `i` | Cycle page theme (light, dark, sepia) |
| `g` | Reload the page |
| `q` | Close the window |

## Non-destructive editing (`pdf-edit-mode`)

Run `M-x pdf-edit-mode` to edit a working copy while keeping the original file untouched:

| Key | What it does |
| --- | --- |
| `[` / `]` | Move the current page backward or forward |
| `D` | Duplicate the current page |
| `d` | Delete the current page |
| `u` | Undo or redo the last page edit |
| `R` | Reset the working copy back to the original PDF |

See also: [06. WRITING](../06.%20WRITING.md).
