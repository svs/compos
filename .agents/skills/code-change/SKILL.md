---
name: code-change
description: Implement or fix code in compos. Use for repository changes, bug fixes, and features. Do not use for read-only explanation or diagnosis.
---

# Change compos code

Complete the request as a durable repository change.

## Establish the contract

1. Read `CLAUDE.md` and the relevant architecture documents.
2. Inspect the current source, tests, and repository state.
3. Convert the request into observable acceptance conditions.
4. Continue through implementation when the user asks to build or fix something.

Do not stop after diagnosis, design, or a successful runtime experiment.

## Choose the implementation layer

Implement policy, commands, modes, keymaps, hooks, and UI behavior in Scheme.
Add Elixir only for a mechanism that Scheme cannot supply.
State the specific missing mechanism before you add Elixir.

Before editing a Scheme package, query `apropos` for relevant APIs.
Query `apropos-components` before choosing or creating UI.
If catalog discovery fails, inspect the defining source instead of repeating the same failing query.

Load a more specific repository skill when its description matches the task.
Follow both skills, with the specific skill controlling its domain workflow.

## Separate experiments from implementation

Use `eval-scheme` to inspect state or test an idea.
Treat every definition and key binding created by `eval-scheme` as temporary.
A temporary definition does not count as written code.
A temporary key binding does not prove the mode keymap uses it.

After an experiment succeeds, implement the behavior in the repository.
Ensure the normal package loader installs it after a daemon restart.

## Implement the durable change

1. Edit the smallest relevant source files.
2. Preserve unrelated changes in the worktree.
3. Put bindings in the owning mode keymap.
4. Put persistent state in the documented buffer-local lifecycle class.
5. Rebuild runtime keys, overlays, folds, and resources during mode setup.
6. Update catalog metadata for public Scheme definitions.

Do not add a core primitive for convenience.
Prefer one narrow primitive only when it unlocks Scheme policy.

## Prove the behavior

Add focused tests for the acceptance conditions and important failure cases.
Drive editor actions through `KeyDispatch.handle_key/1` when a user presses a key.
Test lifecycle behavior when the change depends on reload, reset, restore, or restart.
Test state transitions directly instead of matching source text.

Run the focused tests first.
Run the broad relevant suite when the focused tests pass.
Report unrelated existing failures separately.

Verify UI behavior from within compos.
Inspect buffer text, locals, overlays, render state, and key dispatch as applicable.
Do not use Chrome or external browser automation for compos verification.

## Completion gate

Before reporting completion, inspect the repository diff.
Confirm that the intended source and tests contain the change.
Confirm that focused tests pass.
Confirm restart survival when runtime evaluation was part of the work.

Do not say `implemented`, `fixed`, `built`, or `done` if the result exists only in memory.
Describe incomplete work as a prototype and continue the development loop.
