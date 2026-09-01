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

All are case-insensitive. `(completion-match? LABEL QUERY [STYLE])` is
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

`read-string`, `read-number`, `read-buffer` are completing-read of one
kind. `y-or-n-p` takes one key, `yes-or-no-p` takes the word,
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
