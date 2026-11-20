# morg-mode and morg-agenda-mode

`morg-mode` is compos's major mode for `.md` and `.markdown` files. It combines clean rendered Markdown with Org-style folding, runnable code blocks, inline AI replies, TODO states, and narrowing.

## Open

- Open any `.md` or `.markdown` file (`C-x C-f`). It opens in rendered preview mode by default.
- Press `C-c A` (`morg-agenda`) to open your dated agenda (`morg-agenda-mode`).

## Keys in `morg-mode`

| Key | What it does |
| --- | --- |
| `C-c C-v` | Toggle between rendered page and raw Markdown source |
| `Tab` | Fold or unfold the heading or fenced code block at point |
| `S-Tab` | Cycle overview folding for the whole document |
| `C-c C-n` / `C-c C-p` | Next or previous heading |
| `C-c C-f` / `C-c C-b` | Next or previous sibling heading at the same level |
| `M-<down>` / `M-<up>` | Next or previous landmark (heading, paragraph, block, link) |
| `M-n` / `M-p` | Next or previous link |
| `C-c SPC` | Select the fenced block at point, or the current section |
| `C-x n n` | Narrow the view to the heading at point |
| `C-x n N` | Narrow both the view and the agent's context to this section |
| `C-x n w` | Widen back to the full document |
| `C-c C-c` | Run the fenced code block at point (`sh`, `python`, `elixir`, `node`, `scheme`, `llm`) or refresh `:show-source PATH::NAME` |
| `C-c C-x` | Tangle every block with a `:tangle PATH` header to disk |
| `C-c C-t` | Cycle a heading's TODO state (none -> `TODO` -> `DONE`) |
| `C-c C-s` | Present this Markdown document as a slide deck |
| `M-o` | Open the document's companion chat |

## Inline AI replies (`C-RET`)

Press `C-RET` inside a paragraph to send the document context to the model. The reply streams below as a `> [!agent]` quote block. With point inside a reply:

| Key | What it does |
| --- | --- |
| `c` | Copy the reply without quote markers |
| `e` | Turn the reply into your own prose |
| `r` | Regenerate and replace the reply |
| `d` | Dismiss the reply |
| `s` | Split the reply into its own chat buffer |
| `RET` | Follow up on the reply |
| `Tab` | Fold or unfold the reply |
| `n` / `p` | Jump to the next or previous inline reply |

## Styled tables

A `table` code fence colors cells by rules on its fence header (for example `green>=.7` or `red<.4`). Available colors: `red`, `green`, `yellow`, `blue`, `purple`, `cyan`, and `gray`.

## `morg-agenda-mode` (`C-c A`)

Collects dated headings from `morg-agenda-files` as day cards: `n`/`p` step entries, `Tab` folds a day, `RET` opens the file, `[` and `]` jump by week, `.` returns to today, `g` refreshes, and `C-c C-v` switches to a plain listing.

See also: [writing-mode](writing-mode.md), [06. WRITING](../06.%20WRITING.md).
