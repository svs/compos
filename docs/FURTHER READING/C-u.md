# C-u

`C-u` is the flip.

Every command worth writing has two right answers, not one. Open the file
in this group or a new one? Show the buffer here or in the other window?
Trash the file or delete it for good? Both are correct; they differ in how
often you mean them. Without `C-u` each pair costs two command names and
two keys, and the second name is the one nobody remembers. `C-u` says *the
other one*, so a pair costs one binding and one sentence of docstring.

The plain key is the answer you want all day. The flip is the answer you
want on purpose.

## What it is

`C-u` sets the frame's prefix argument: one value, for the next command
only. The command reads it; the dispatcher clears it when the command
ends.

| keys | raw value |
|------|-----------|
| `C-u` | `(4)` |
| `C-u C-u` | `(16)` |
| `C-u 3`, `M-3` | `3` |
| `C-u - 2` | `-2` |
| `M--` | `-` |
| nothing | `#f` |

`(current-prefix-arg)` returns the raw value. `(prefix-numeric-value RAW)`
turns it into an integer, `#f` into 1. A command declared
`(interactive 'P)` receives the raw value, `(interactive 'p)` the number.
editor.scm.

## Two ways to read it, never both

**A count multiplies.** `C-u 8 C-n` moves eight lines; `C-u 4 x` inserts
`xxxx`. The motion, deletion, kill, scroll, newline and undo commands take
a count. Read it with `'p`.

**A flip is a boolean.** `(and (current-prefix-arg) #t)`. The value is
discarded: `C-u` and `C-u 17` mean the same thing. Read it with `'P`, or
call `current-prefix-arg` directly.

A command that has a natural count has a count. Its flip, if it wants one,
needs its own command name. `C-u C-n` cannot both move four lines and move
the other way.

## Choosing which answer is the default

The two answers are equally correct. They are not equally frequent. In
order:

1. **Frequency decides the default.** The bare key is the common case.
2. **The flip is the deliberate one.** Reaching for `C-u` is a sentence you
   said on purpose, so it is where the wider blast radius goes. `C-x C-f`
   visits a file in the group you are in; `C-u C-x C-f` asks which group.
3. **Reversible by default, irreversible behind the prefix.**
   `delete-file` moves the file to the trash. `C-u` deletes it for good.
4. **The flip is still the same command.** `C-u C-x b` switches buffers —
   it only changes where the buffer lands. If `C-u` would do something you
   cannot describe as "the same thing, the other way", it is a second
   command, not a flip.
5. **The docstring says it.** `"Switch to a buffer; with a prefix, show it
   in another window"`. That sentence is the entire discovery surface:
   `M-x`, `C-h k`, apropos and an agent all read it and nothing else.

## The flips compos has

| command | plain | with `C-u` |
|---------|-------|-----------|
| `find-file` (`C-x C-f`) | visit in this group | choose the group |
| `project-switch-project` (`C-x p p`) | enter the project's group | choose the destination group |
| `chat-new` (`C-c n`) | new chat in this group | choose or create its group |
| `opencode` | this group's terminal | choose a group |
| `chat-switch-prompt` | switch here | show it in another window |
| `delete-file` | to the trash | delete for good |
| `set-mark-command` (`C-SPC`) | set the mark | go back to the previous mark, pop the ring |

Three axes recur, and they are the ones to reach for first: **here or the
other window**, **this group or a chosen group**, **reversible or final**.

## Mechanics

**The value is frame-local.** Two clients are two users; a `C-u` pending in
one frame is invisible to the other. `Editor.prefix_arg/1`.

**One command consumes it.** `finish_command` clears the prefix unless the
command that just ran is itself `universal-argument`, `digit-argument` or
`negative-argument` — those three keep it and echo it. key_dispatch.ex.

**While it is pending, the digits are rebound.** `universal-argument-hook`
arms `universal-argument-map` as the frame's overriding map until the next
command, so `3`, `-` and a second `C-u` extend the argument instead of
inserting themselves. `M-0` .. `M-9` and `M--` reach the same commands
without a `C-u` first.

**`M-x` carries it across the minibuffer.** `execute-extended-command`
finishes before its callback runs, so it saves the raw value, restores it
around `run-command`, and clears it after. `C-u M-x foo` gives `foo`
exactly the view a key binding would.

**The echo area shows what is pending**: `C-u`, `C-u 4`, `3`, `-`.

## Writing one

```scheme
(define-command "chat-switch-prompt"
  "Switch to a chat by its title; with a prefix, show it in another window"
  (lambda ()
    (let* ((other-window? (and (current-prefix-arg) #t))
      ...)))
```

Both sides need a test. universal_argument_test.exs covers the machinery
once, for everyone: the raw values, the multiply, `M-x` forwarding, the
clear. A command's own test presses `["C-u", ...]` and asserts the other
answer — group_switch_preview_test.exs, project_search_test.exs.

## When it is not a flip

- **Three answers is not a flip.** Prompt, or write a transient.
- **A flip nobody can guess is a hidden feature.** If the docstring cannot
  say it in six words, split the command.
- **`C-u` is not a confirmation.** Destructive-behind-the-prefix is fine;
  destructive-behind-the-prefix without the docstring saying so is a trap.

## Known gap

`C-x b` is bound to `ibuffer-prompt`, whose body reads no prefix argument
and passes no `WHERE` to `ibuffer-pick!`. No buffer-switch command reads
the prefix; `chat-switch-prompt` is the only switch prompt that flips to the
other window, and it switches chats. switch.scm's own
header line and docs/groups.md both describe `C-u C-x b` as the
other-window flip, and group_switch_preview_test.exs asserts it. Either the
binding or the docs are wrong.

## See also

docs/COMMANDS.md — the interactive spec, `this-command`, the mark ring.
docs/KEYMAPS.md — prefix *keys*, which are a different thing with the same
word in them.
