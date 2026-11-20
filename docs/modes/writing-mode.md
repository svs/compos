# writing-mode and annotate-mode

`writing-mode` provides distraction-free composition, and `annotate-mode` adds anchored margin notes to any text document.

## `writing-mode`

- `M-x writing-mode`: toggle centered prose (`writing-measure`), hidden line numbers, `visual-line-mode`, and a live word count and reading time (`writing-wpm`) in the modeline.
- `M-x write`: enable `writing-mode` and open the three-pane writing workspace (document, scratch buffer, and group chat).
- `M-x count-words`: report the word count of the current buffer.
- `M-x preview-font-toggle`: switch rendered pages between serif and monospace.
- Pasting an image saves the file and inserts a relative Markdown image link.

## `annotate-mode` and `annotations-mode`

Margin notes anchor to their matched text and move with it as you edit above them. Notes persist on disk and survive restarts.

| Key or command | What it does |
| --- | --- |
| `C-c ! a` (`annotate-add`) | Add a note on the selected region or current line |
| `M-n` / `M-p` | Jump to the next or previous note |
| `C-c ! m` (`annotate-margin`) | Show or hide the note margin |
| `C-c ! l` / `M-x annotate-list` | Open the `*annotations*` list (`annotations-mode`) |

In `annotations-mode`, `<left>` and `<right>` filter by author tab, `RET` visits the note, `r` resolves it, `d` dismisses it, `R` replies, `s` asks an agent for a suggested fix, and `y` applies that fix.

See also: [morg-mode](morg-mode.md), [06. WRITING](../06.%20WRITING.md).
