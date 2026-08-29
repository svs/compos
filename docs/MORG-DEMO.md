# morg — markdown with org habits

This file is a live demo. Open it in the editor and press the keys.

- `TAB` on a heading folds its subtree. `TAB` again opens it.
- `TAB` on a fence (or inside a block) folds the code block.
- `S-TAB` folds the whole file to an overview.
- `C-c C-t` on a heading cycles no state, `TODO`, and `DONE`.
- `C-c C-c` inside a code block runs it. The output lands in a
  `result` fence under the block. Run it again and the result is
  replaced, not appended.
- `C-c C-x` writes each block with `:tangle PATH` to its source file.
- `C-c C-v` renders the page, as with any markdown buffer.

## 1. Folding

Put point on the heading above and press `TAB`. This paragraph and
everything under the heading disappears behind a fold marker. The fold
survives a daemon restart, because it lives in a buffer-local.

### A deeper heading

Subtrees nest the way org subtrees nest. A level-3 heading folds
inside its level-2 parent.

## 2. TODO states and the agenda

Put point on this heading and press `C-c C-t`. `M-x morg-agenda` shows
dated headings from `morg-agenda-files`. Press `t` on an agenda entry
to cycle the same state. Press `[` or `]` to move by one week. Press `.`
to return to today.

### TODO Review the Morg agenda <2026-08-21>

The agenda uses timestamps in the text. It does not require a calendar UI.

## 3. Run a shell block

Point anywhere in the block, then `C-c C-c`:

```sh
date "+%Y-%m-%d %H:%M"
uname -sm
```

## 4. Run a scheme block

A scheme block does not go to a subprocess. The editor's own
interpreter evaluates it, so it can talk to the editor:

```scheme
(length (buffer-list))
```

The result below tells you how many buffers this daemon holds.
Long list results wrap at `morg-babel-scheme-result-width`. Property-list
keys stay beside their values.

## 5. Run an elixir block

```elixir
defmodule MorgDemo do
  def fib(0), do: 0
  def fib(1), do: 1
  def fib(n), do: fib(n - 1) + fib(n - 2)
end

IO.puts(Enum.map_join(0..10, " ", &MorgDemo.fib/1))
```

This block also shows the highlight: `defmodule`, `def`, and the
string render with the same theme faces a real elixir buffer uses.

## 6. Errors are results too

Stderr folds into the result block, so a failing run explains itself:

```sh
ls /no/such/directory
```

## 7. What morg does not misread

Inline markup still works: `code`, **bold**, _italic_, and a
[link](https://example.com). And a hash inside a fence is code, not
a heading — this block folds with its section:

```sh
# a comment, not a heading
echo "the scan carries fence state through the walk"
```

## 8. Result blocks

A `result` fence is inert. `C-c C-c` inside one refuses to run it.
A result is replaced only when it sits directly under its source
block; this orphan just renders dim:

```result
stale output, no source block above
```

## 9. Tangle source files

Add `:tangle PATH` after the language. Relative paths start beside this
Morg file. Blocks with the same path join in document order. Press
`C-c C-x` or run `M-x morg-tangle` to write all marked blocks.

A tangled `csv` block previews data in Morg without a language runner. Press
`C-c C-c` to write a `result-csv` block with a bold header. The rendered Morg
page also shows the CSV as a table. When the target file exists, both previews
read it relative to the Morg document. Otherwise, they read the block body.
The preview shows five CSV lines by default. Add `:lines N` to choose another
limit.

```csv :tangle demo/people.csv :lines 3
name,role
Ada Lovelace,mathematician
Grace Hopper,computer scientist
Margaret Hamilton,software engineer
```

```elixir :tangle demo/generated.exs
IO.puts("This file came from Morg")
```
