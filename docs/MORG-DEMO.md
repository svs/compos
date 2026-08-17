# morg — markdown with org habits

This file is a live demo. Open it in the editor and press the keys.

- `TAB` on a heading folds its subtree. `TAB` again opens it.
- `TAB` on a fence (or inside a block) folds the code block.
- `S-TAB` folds the whole file to an overview.
- `C-c C-c` inside a code block runs it. The output lands in a
  `result` fence under the block. Run it again and the result is
  replaced, not appended.
- `C-c C-v` renders the page, as with any markdown buffer.

## 1. Folding

Put point on the heading above and press `TAB`. This paragraph and
everything under the heading disappears behind a fold marker. The fold
survives a daemon restart, because it lives in a buffer-local.

### A deeper heading

Subtrees nest the way org subtrees nest. A level-3 heading folds
inside its level-2 parent.

## 2. Run a shell block

Point anywhere in the block, then `C-c C-c`:

```sh
date "+%Y-%m-%d %H:%M"
uname -sm
```

## 3. Run a scheme block

A scheme block does not go to a subprocess. The editor's own
interpreter evaluates it, so it can talk to the editor:

```scheme
(length (buffer-list))
```

The result below tells you how many buffers this daemon holds.

## 4. Run an elixir block

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

## 5. Errors are results too

Stderr folds into the result block, so a failing run explains itself:

```sh
ls /no/such/directory
```

## 6. What morg does not misread

Inline markup still works: `code`, **bold**, _italic_, and a
[link](https://example.com). And a hash inside a fence is code, not
a heading — this block folds with its section:

```sh
# a comment, not a heading
echo "the scan carries fence state through the walk"
```

## 7. Result blocks

A `result` fence is inert. `C-c C-c` inside one refuses to run it.
A result is replaced only when it sits directly under its source
block; this orphan just renders dim:

```result
stale output, no source block above
```
