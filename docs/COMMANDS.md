# Commands

A command is a name, a docstring, and a function. `M-x`, a key, an agent
and a test all run a command by name. `define-command` registers it.

## Arguments

A command may take arguments. The spec says where they come from when a
key runs the command, as `(interactive "p")` does in Emacs.

```scheme
(define-command "next-line" "Move point down one line" (interactive 'p)
  (lambda (n) ...))
```

| code | argument |
|------|----------|
| `'p` | the numeric prefix argument, 1 without one |
| `'P` | the raw prefix argument: `(4)` for `C-u`, a number, `-`, or `#f` |
| `'r` | the region start and end, two arguments |
| `'b` | the current buffer |
| `'d` | point |
| `'m` | the mark, or point |
| `"sPrompt: "` | a string from the minibuffer |
| `"nPrompt: "` | a number from the minibuffer |
| `"fPrompt: "` | a file name from the file prompt |
| `"bPrompt: "` | a buffer name |

A prompt is asynchronous, so the rest of the collection runs when the
answer arrives. `(command-call NAME ARG ...)` runs the function with
explicit arguments. `(command-function NAME)` is the function.

## The prefix argument

`C-u` starts it, digits and `-` extend it, `M-1` .. `M-9`, `M-0` and
`M--` set it in one key. The motion, deletion, kill, scroll, newline and
undo commands take it as a count. `prefix-numeric-value` turns the raw
value into a number.

## this-command and last-command

The dispatcher sets `this-command` as a command starts and makes it the
next `last-command` when it ends. A command may change what the next one
sees with `set-this-command!`. Both are per frame: two clients are two
users. `yank-pop` reads `last-command`, and so does the kill ring.

## The kill ring

A kill command that follows a kill command grows the newest entry: `C-k
C-k C-k` yanks back as one piece. `kill-text!` applies the rule;
`kill-new`, `current-kill`, `kill-append!` are the Emacs names.
`*kill-commands*` lists the commands that count as a kill.

## Undo

One command is one undo step. `undo-boundary!` splits the step in
progress, so the edits before it undo apart from the edits after it.
`break-undo-chain!` does not make a boundary: it ends a run of undos,
so the next undo reverses them, which is redo.

## The mark ring

`C-SPC` pushes the old mark onto the buffer's ring and sets a new one.
`C-u C-SPC` goes back to the mark and pops the ring; a set mark is an
active region here, so the pop leaves no region behind. `C-x C-SPC`
walks the global mark ring back across buffers. `push-mark!` and
`pop-to-mark!` are the functions.

## Registers

A register is one character. `C-x r SPC` saves point and the buffer,
`C-x r j` jumps back to it or restores saved windows, `C-x r s` saves the
region's text, `C-x r +` appends to it, `C-x r i` inserts it, `C-x r w`
saves the frame's windows, `C-x r v` says what a register holds. The
registers persist with the desktop. packages/register.scm.
