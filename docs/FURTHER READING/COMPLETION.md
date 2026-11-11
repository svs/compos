# Completion

Two surfaces, one engine. The minibuffer prompt (M-x, find-file, the
buffer prompt) and the at-point popup (completion-at-point) both narrow
through `Compos.Core.Candidates`. The prompt chooses the style; the
engine applies it.

## Styles

| style | the input matches when |
|-------|------------------------|
| `flex` (default) | one term is a subsequence; several terms are substrings in any order |
| `substring` | every term is a substring |
| `prefix` | the input is a prefix of the label |
| `regexp` | every term is a regexp; a bad one matches nothing |
| `exact` | the label is the input |

All but `exact` are case-insensitive. `(completion-match? LABEL QUERY [STYLE])` is
the same matcher for any Scheme that narrows: the list mode filter and
the switcher use it, so `*scratch*` is a name and `(` is a character.

## completing-read

```scheme
(completing-read "Theme: " (theme-names)
  (lambda (name) (load-theme name))
  'require-match #t 'history 'theme 'default "paper")
```

Asynchronous: K gets the choice. COLLECTION is rows, or a procedure of
the input that answers rows. The options: `'predicate` keeps rows,
`'require-match` refuses free text with `[No match]`, `'initial` fills
the input, `'default` answers an empty input and leads the list,
`'history` names the ring to read and to push on, `'category` picks the
marginalia annotator, `'style` picks the match style.

`read-string` is completing-read with no candidates. `y-or-n?` takes one key, `yes-or-no?` takes the word,
`read-char-choice` takes one key from a list.

## History

A history is a ring per symbol, persisted across sessions. `M-p` puts
the previous item in the input, `M-n` the next, and past the newest the
typed text comes back. `history-order` leads a candidate list with the
remembered items.

## One prompt at a time

A prompt that opens while another is up cancels the outer one, so its
cancel handler restores what it displaced. Emacs without
`enable-recursive-minibuffers` signals an error; here the new prompt
wins and the echo area says so.

## The popup

A capf source answers `(START END CANDIDATES)`, or the same with
`'exclusive 'no` after it, which yields to the next source when
CANDIDATES is empty. END may lie past point: accept replaces
START..END, so a source that completes over a suffix names the whole
word. The popup's keys are the ` *completion*` keymap.

## While you type

The capf framework answers "what completes here". It never asks: `M-/`
was the only caller. `completion.scm` is the asking. A mode opts in
with `(capf-auto-watch! BUF)` from its mode hook, and from then on
typing in that buffer offers what `M-/` would have offered. scheme-mode
and chat-mode opt in; nothing else does yet.

The watch is the `on-change!` plus `debounce!` pattern the checkers use,
so a burst of keys costs one collect. Only a person typing forward
asks: an agent edit, an undo and a delete leave the popup alone, since
the popup's own `DEL` narrows it.

| setting | default | meaning |
| --- | --- | --- |
| `completion-auto` | `#t` | offer completions while you type |
| `completion-auto-delay` | `150` | milliseconds of quiet before asking |
| `completion-auto-prefix` | `2` | fewest characters before point |

Two rules bound it.

The frame must already stand on the buffer. `completion-show!` measures
the range it replaces against the frame's own buffer, not against a
buffer a caller scoped with `with-current-buffer`. A popup raised for
any other buffer carries a range that names the wrong file, and
accepting it cuts that file. The guard also answers the question that
matters anyway: a popup in a buffer nobody looks at is noise.

The mode's sources must answer in the call. An asynchronous source
returns `#f` and shows the popup later from its own callback, so the
collect falls through to dabbrev, dabbrev paints, and the server's
answer replaces it a moment later. `M-/` hides that; typing would show
it on every key. lsp-mode therefore stays manual until a source can
answer `'pending`.
