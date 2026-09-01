# Fenced blocks: the kind registry

A Morg document is text. A fenced block's info string names its kind.
One registration gives a kind its paint, its runner, and its help.
The registry lives in `priv/packages/morg/morg-kinds.scm`.

## The pattern

1. The bytes are the document. Every view is derived from a scan, never stored.
2. The scan yields blocks: `(START END KIND INFO)`. Byte offsets are identity.
3. Paint decorates ranges. It never replaces text.
4. An action on a block lands text at the block: the result fence below it.

The fence itself supplies the scan (`morg-scan`), folding, the region lift,
relocation while a block runs, and the result landing. A kind declares only
what differs.

## One registration

```scheme
(define-fence-kind! "mermaid"
  "Renders the body as a diagram."
  'ts-lang #f
  'run (lambda (buf scan fstart e lang body)
         (morg-babel-insert-result! buf fstart (mermaid-render body))
         (list 'ok lang)))
```

Keys a kind can declare:

| key | value | meaning |
|---|---|---|
| `ts-lang` | string or `#f` | the tree-sitter language for the body |
| `body-face` | string | one face for every body line |
| `line-face` | fn | `(FN LINE)` -> a face for that line, or `#f` |
| `header-face` | string | a face for the first body line |
| `runnable` | `#f` | the kind refuses to run |
| `run` | fn | `(FN BUF SCAN FSTART ENTRY LANG BODY)` -> `(ok LANG)`, `(pending LANG)`, or `(error MSG)` |
| `interpreter` | string | the interpreter the shared shell runner uses |

An unregistered info string still paints: its own name is tried as a
tree-sitter grammar. `C-c C-c` on it answers `No runner for NAME`.

Rules:

- Registration by name replaces the old entry. A reload does not stack.
- Two packages can own two aspects of one kind. The second package calls
  `fence-kind-merge!`, not `define-fence-kind!`.
- Every registration lands in the catalog: `(apropos "diff" 'kind 'fence-kind)`
  finds it, `(describe-fence-kind "diff")` explains it.
- A kind's verbs are named commands. No registration names a key.

## The bundled kinds

- `morg-kinds.scm` registers the paint-only kinds: `result`, `result-scheme`,
  `result-csv`, `diff`, `patch`, and the grammar aliases `jsx`, `ts`, `ex`.
- `morg-babel.scm` registers the runners: the shell rows of
  `*morg-babel-runners*`, `scheme`, `llm`/`ask`/`chat`, and `csv`.

A `diff` or `patch` fence paints with the theme's `diff-add`, `diff-del`,
`diff-hunk`, and `diff-file` faces, in the source view and in the preview
rows. It does not run.

## The consumers

- `morg.scm` (`morg-line-spans`, `morg-refontify!`) asks
  `fence-kind-line-face` and `fence-kind-body-spans` for the plain source view.
- `markdown-mode.scm` (`markdown--line-spans`, `markdown-refontify!`) asks the
  same two functions for the preview rows.
- `morg-babel.scm` (`morg-babel-execute`) asks `fence-kind-runnable?` and
  `fence-kind-run` to dispatch `C-c C-c`.
- The rendered page (`markdown/html.ex`) offers the run key by the list the
  registry pushes through `preview-run-langs!` on every registration.
- `llm-mode--blocks` in `editor.scm` derives its reply-landing blocks from
  `morg-scan`, the one fence-aware line scanner.

## Chrome

A chrome attachment draws text the buffer does not hold: a badge, a key
hint, a chip. Build one with `(chrome-before POS TEXT CLASS)` or
`(chrome-after POS TEXT CLASS)` and put it in an `overlay-set!` range list
beside the face spans. It stands at one byte, holds zero bytes, and the
caret walks over it: the renderer draws a zero-length island
(`class="chrome-seg CLASS"`, `data-len="0"`), so the client's byte mapping
skips it and the saved file never sees it.

A fourth argument is a click id: `(chrome-after POS TEXT CLASS "verb:7")`
routes a click through the same `on-block-click!` registry a block tree
uses, so chrome verbs and block verbs are one vocabulary.

The first user is the fence chip: in the preview rows, the open fence of a
named block steps back and a chip names its kind — `diff`, or
`sh · C-c C-c run`. The chip text comes from `(fence-kind-chip LANG
[RUN-KEY])`: the declared `'chip`, else the info string; a runnable kind
adds the run key. The painter reads the key from the buffer's own keymap
with `(key-for-command "morg-babel" BUF)`, so a rebind changes the page
and no string hard-codes a key.

## Debt this registry names

- The gutter and end-of-line vocabulary of `docs/ANNOTATIONS.md` can now
  be built on chrome attachments.

Tests: `priv/tests/morg-kinds-test.scm`, plus the babel and paint sections of
`priv/tests/morg-test.scm` and `priv/tests/markdown-mode-test.scm`.
