# Fenced blocks: the kind registry

A Morg document is text. A fenced block's info string names its kind.
One registration gives a kind its paint, its runner, and its help.
The registry lives in `priv/packages/morg/morg-kinds.scm`.

## The pattern

1. The bytes are the document. Every view is derived from a scan, never stored.
2. The scan yields blocks: `(START END KIND INFO)`. Byte offsets are identity.
3. Paint decorates ranges. It never replaces text.
4. An action on a block lands text at the block: the result fence below it.

The fence itself supplies finding (`block-list`/`block-at`, by the
markdown tree-sitter grammar, scan-walked where no grammar is loaded),
folding, the region lift, tracking while a block runs, and the result
landing. A kind declares only what differs.

## One registration

```scheme
(define-fence-kind! "mermaid"
  "Renders the body as a diagram."
  'ts-lang #f
  'run (lambda (buf b lang body)
         (result-block-insert! buf (nth 0 b) (mermaid-render body))
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
| `run` | fn | `(FN BUF BLOCK LANG BODY)` -> `(ok LANG)`, `(pending LANG)`, or `(error MSG)`; BLOCK from the finder |
| `interpreter` | string | the interpreter the shared shell runner uses |
| `keymap` | string | the keymap in force while point is inside a block of this kind; a kind with `keys` and no keymap gets one built from them |
| `row-spans` | fn | `(FN START LINE LEN HEAD?)` -> the spans that draw one body line in the page instead of the code row |

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
- `editor/blocks/csv-block.scm` gives `csv` and `result-csv` their page
  rows: a comma outside quotes is a column bar, the first row is the
  head, and a wide row scrolls right.
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

## The blocks

Each block is its own file under `priv/editor/blocks/`, handles itself,
and leans on `block.scm` for the common mechanics: reading and replacing
its text, landing below a passage, fence build and strip by structure,
finding itself again through edits by a tracking overlay, verb key
binding, and the head-hunk-tail line diff.

- **The babel block** (`run-block.scm`): a fenced block that runs.
  `C-c C-c` dispatches through the kind registry; the output lands in
  the result block below it. A running block is tracked by overlay, so
  the document can move while the command works.
- **The result block** (`result-block.scm`): the output below the block
  that made it. `result-block-insert!` finds it and replaces it; a later
  run lands in the same place. It does not run.
- **The diff block** (`diff-block.scm`): two texts waiting for a
  decision, indicated by text alone:

      ```diff <state> <keys from the keymap>
      ...the state's rendering...
      ```

  The states are `theirs` (their text, the default), `all` (the unified
  diff), and `ours`. Changing state is a redraw of the same two texts;
  the fence line carries the kind, the state, and the keys, read from
  the buffer's keymap at land time. Accepting lands theirs where ours
  stood; rejecting removes the block; an edited block is your text and
  stays. A plain ` ```diff ` pasted from git is only the kind's paint:
  no record, no verbs.
- **The rewrite block** (`llm-rewrite.scm`): region -> LLM -> a diff
  block below the passage. It owns the directives, the prompt, the
  reply cleaning, and the review loop `C-c e` opens; the block it lands
  is a diff block. Any other maker — a merge tool, an agent — lands one
  the same way, through `diff-block-propose!`.

The preview adds no affordance to any of them. It renders the same text
fancy: the backticks step back, and a kind that declares a `'fence-face`
keeps its info string visible in that face.

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
