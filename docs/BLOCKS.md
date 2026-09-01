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
         (result-block-insert! buf fstart (mermaid-render body))
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
- `editor/blocks/run-block.scm` registers the runners: the shell rows of
  `*morg-babel-runners*`, `scheme`, `llm`/`ask`/`chat`, and `csv`. Its
  result lands through `editor/blocks/result-block.scm`, and a running
  block is found again by a `block.scm` tracking overlay, not a
  remembered offset.

A `diff` or `patch` fence paints with the theme's `diff-add`, `diff-del`,
`diff-hunk`, and `diff-file` faces, in the source view and in the preview
rows. It does not run.

## The consumers

- `morg.scm` (`morg-line-spans`, `morg-refontify!`) asks
  `fence-kind-line-face` and `fence-kind-body-spans` for the plain source view.
- `markdown-mode.scm` (`markdown--line-spans`, `markdown-refontify!`) asks the
  same two functions for the preview rows.
- `run-block.scm` (`morg-babel-execute`) asks `fence-kind-runnable?` and
  `fence-kind-run` to dispatch `C-c C-c`.
- The rendered page (`markdown/html.ex`) offers the run key by the list the
  registry pushes through `preview-run-langs!` on every registration.
- `llm-mode--blocks` in `editor.scm` derives its reply-landing blocks from
  `morg-scan`, the one fence-aware line scanner.

## The diff block

A live diff block holds two texts and waits for a decision. It is
indicated by text alone:

    ```diff <state> <keys from the keymap>
    ...the state's rendering...
    ```

The states are `theirs` (their text, the default), `all` (the unified
diff), and `ours`. Changing state is a redraw of the same two texts.
The fence line carries every affordance: the kind, the state, and the
keys, read from the buffer's keymap at land time. Accepting lands theirs
where ours stood; rejecting removes the block; an edited block is your
text and stays. The block lives in `priv/editor/blocks/diff-block.scm`;
llm-rewrite (`priv/editor/blocks/llm-rewrite.scm`) is one creator — a
merge tool or an agent can call `diff-block-propose!` the same way.

The preview adds no affordance. It renders the same text fancy: the
backticks step back, and a kind that declares a `'fence-face` keeps its
info string visible in that face. A plain patch pasted as ` ```diff ` is
the other diff type: kind paint only, no record, no verbs.

## Chrome

A chrome attachment draws text the buffer does not hold, as a zero-length
island (`chrome-before` / `chrome-after` in an `overlay-set!` range list;
optional click id through the block-click registry). The mechanism stands;
no bundled feature uses it, because affordances come from the text.

## Debt this registry names

- The gutter and end-of-line vocabulary of `docs/ANNOTATIONS.md` can now
  be built on chrome attachments.

Tests: `priv/tests/morg-kinds-test.scm`, plus the babel and paint sections of
`priv/tests/morg-test.scm` and `priv/tests/markdown-mode-test.scm`.
