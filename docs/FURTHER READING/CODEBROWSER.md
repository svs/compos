# Code browsing

Code-browse is a minor mode for a source buffer. It turns a file into a
tree of definitions, so you can read the shape of the code before you read
the lines. It uses the tree-sitter grammar when the buffer has one, and the
indentation when it does not. The mode is in `scheme/packages/code.scm`.

## Turn it on

Run `M-x code-browse`. The echo area shows the keys. Run it again, or press
`q` or `RET`, to leave. A buffer that already answers single keys keeps them:
the mode refuses a diff or another reader surface and says so.

While it is on, the modeline names the node at point and the buffer tints
it. Point does not move when the mode draws.

## Keys

| Key | What it does |
| --- | --- |
| `h` | Go to the node that encloses this one |
| `l` | Go into the first block inside this node |
| `j` | Go to the next node at this level |
| `k` | Go to the previous node at this level |
| `TAB` | Fold or unfold the body of this node |
| `RET`, `q` | Leave code-browse |
| `M-.` | Go to the definition of the symbol at point |

A long file folds its top-level definitions when the mode turns on. `TAB`
on a one-line definition folds the next node above it that has a body.

## The outline

`M-x imenu` (`s-i`) lists every definition with its line, kind, name, and
doc. The doc is the comment or string that sits above the definition, or
the one inside it. The list nests a method under its class.

In any file buffer, `M-.` (`code-goto-definition`) goes to the definition
of the symbol at point. It asks the language server when one is attached,
and reads the file itself when none is.

## For agents

The same outline is an API. `(code-outline BUF)` gives every definition as
`(LINE KIND NAME DOC)`. `(code-read BUF LINE)` gives the definition that
holds a line. `(code-find BUF TEXT)` finds a definition by name or doc.
`(code-replace! BUF LINE NEW)` and `(code-sexp-replace! BUF ANCHOR NEW)`
edit one definition and keep the rest of the file.

Read `docs/FURTHER READING/BLOCKS.md` for the fenced blocks a document can
hold, and `docs/FURTHER READING/PANES.md` for how the windows show them.
