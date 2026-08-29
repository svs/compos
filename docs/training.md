# Learn compos

## Contents

- [Welcome to compos](#welcome-to-compos)
- [How to read Emacs notation](#how-to-read-emacs-notation)
- [Your first five minutes](#your-first-five-minutes)
- [Commands and M-x](#commands-and-m-x)
- [Buffers, files, and windows](#buffers-files-and-windows)
- [Discovering what you can do](#discovering-what-you-can-do)
- [Working with the companion](#working-with-the-companion)
- [Configuration](#configuration)
- [A small guided exercise](#a-small-guided-exercise)
- [Quick reference](#quick-reference)

## Welcome to compos

compos is an Emacs-style editor. You work in buffers, run named commands, and use a companion chat when you want help.

You do not need to learn everything at once. Begin by opening a file, making a change, and saving it. The rest can be discovered as you work. If you want to know why emacs is built the way it is and why you should be interested, read Why?


## How to read Emacs notation

Emacs writes key combinations in a compact form.

- `C-` means hold Control.
- `M-` means hold Meta. On most keyboards, use Alt or Option.
- `RET` means Return or Enter.
- A space between keys means press them in sequence.

For example, `C-x C-f` means hold Control and press X, then hold Control and press F.

## Your first five minutes

Open a file with `C-x C-f`. Type a path and press `RET`.

Edit the file as you would in another text editor. Then:

- Use `C-x C-s` to save.
- Use `C-/` to undo.
- Use `C-g` to cancel a command you started by mistake.
- Use `C-x k` to close the current buffer.

Don't worry about remembering these keys for the moment. You only need to really remember M-x. Compos, like Emacs has an extensive yet unobtrusive help system to guide you every step of the way. To understand the art of navigating the interface, read [Interface](INTERFACE.md).






## Commands and M-x

Pretty much every thing in Compos is the result of running a command. When you press a key to type, internally, Compos sends `insert-char` command. And all of these commands are available to you to turn into whatever you want. No other 'text editor' gives you this power and we will be using this power to bring all of our work into Compos, where we can mold it like clay or play it like a piano.

Press `M-x`.You will see a little window pop up. This window is known as the minibuffer. It pops up whenever the system needs to ask you a question. It's purposely kept unobtrusice to never take away from the work.  To run a named command, type part of a command name. You will see that you don't need to remember very much. Something to do with files? type `file`. You will see the command name and description and what's that? Also the shortcut key. Use a command once or twice, then try out the shortcut key. It goes into your short term muscle memory. 

Select the command `find-file`, then press `RET`. You will see a very efficient way to pick directories, and just start typing the name of the file and hit `RET` when it is highlighted. The file will open.

A shortcut runs the same named command that `M-x` runs. The command name is stable, so you can use `M-x` even when you do not remember its shortcut.

Try `M-x apropos` to search the live command and function catalog.

## Buffers, files, and windows

A **file** is stored on disk. A **buffer** is the editor's working copy of some text. A **window** is an area of the screen that displays a buffer.

One buffer can appear in more than one window, and some buffers do not belong to files.

- `C-x b` switches buffers.
- `C-x C-f` finds a file.
- `C-x 4 f` opens a file in another window.
- `C-x 0` closes the current window.
- `C-x 1` keeps only the current window.

Closing a window does not delete its buffer or file.

## Discovering what you can do

You are not expected to memorize every command.

- `C-h k` asks what the next key does.
- `C-h m` shows the current major mode and its local keys.
- `M-?` explains the current buffer and the name at point.
- `M-x describe-mode` describes the current major mode.
- `M-x apropos` searches for commands and functions by topic.

A major mode adapts the editor to the kind of work in the current buffer.

## Working with the companion

Every work buffer can have a companion chat. The companion knows the buffer group.

- `C-c w` opens the companion chat in its side window.
- `C-c RET` asks the companion a question without leaving the work buffer.
- [Ask the companion to summarize this major mode](compos:training/summarize-mode).

Try asking: `What can I do in this mode?`, `Which keys matter here?`, or `Explain the text at point.`

## Configuration

compos can be adjusted without editing its source code. Settings control behavior, while faces control appearance.

Run `M-x customize` to browse the available options. Change a value and save it to keep the change after restarting the editor.

If you know part of a setting's name, use `M-x customize-apropos` to search for it. Start with a small change, such as a font, color, or display preference.

## A small guided exercise

1. Press `C-x C-f`, choose a file, and press `RET`.
2. Type a short line of text.
3. Undo it with `C-/`, then type it again.
4. Save with `C-x C-s`.
5. Open another file in a second window with `C-x 4 f`.
6. Ask the companion: `What mode am I in, and what can I do here?`

## Quick reference

| Task | Key or command |
| --- | --- |
| Cancel the current command | `C-g` |
| Undo | `C-/` |
| Save | `C-x C-s` |
| Find a file | `C-x C-f` |
| Switch buffers | `C-x b` |
| Run a named command | `M-x` |
| Describe a key | `C-h k` |
| Describe the current mode | `C-h m` |
| Open companion chat | `C-c w` |
| Ask the companion | `C-c RET` |
