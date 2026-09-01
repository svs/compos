# Diff blocks

`diff-block.scm` implements an interactive, temporary diff block. It presents a proposed change inline, lets the user inspect different views, and lets the user accept or reject the proposal.

## Purpose

A diff block records an original text and a proposed replacement. It inserts the proposal after the original text and keeps both ranges in tracking overlays.

The block stores:

- the original text, called **ours**;
- the proposed replacement, called **theirs**;
- the text after the block, called the **tail**;
- an optional note; and
- the current display state.

The block uses a `diff` fence. Its fence line contains the current state and the available command keys.

## States

The block supports three display states:

- `theirs` shows only the proposed text. This is the default state.
- `all` shows common context, the original hunk, and the proposed hunk.
- `ours` shows only the original text.

Changing state redraws the same stored texts. It does not commit or reject the proposal.

## Diff calculation

The implementation splits both texts into lines. It finds the common prefix and common suffix. The unmatched middle sections become the original and proposed hunks.

The resulting parts are:

```text
(HEAD-CONTEXT OURS-HUNK THEIRS-HUNK TAIL-CONTEXT)
```

This is a simple line-based comparison. It does not calculate a general edit script.

## Rendering

`diff-block-ours-text`, `diff-block-theirs-text`, and `diff-block-all-text` build the three fence representations. `diff-block--render` selects one representation from the current state.

The fence line includes the state name and the keys for accepting, rejecting, and cycling. The code reads these keys from the buffer keymap when it lands the block. The displayed help therefore follows the active bindings.

## Tracking and faces

The block uses overlays for the original source range and the inserted diff block. The overlays track edits above the block. The block can therefore find its current byte ranges after other edits move it.

`diff-block--paint!` applies the source face, the block boundary face, and line-specific faces. The `all` state uses add and delete faces according to each line prefix.

## Proposing a block

```scheme
(diff-block-propose! BUF START END OURS THEIRS NOTE)
```

`diff-block-propose!` reads `START..END` and checks that the text still equals `OURS`. It returns `changed` when the source changed before the proposal landed.

When the source matches, it finds the tail, binds the diff commands, builds the `theirs` fence, lands it after the original text, records the ranges, and returns `ok`. This check prevents a stale proposal from replacing newer text.

## Updating a proposal

```scheme
(diff-block-update! BUF THEIRS NOTE)
```

`diff-block-update!` replaces the proposed text and redraws the block. It keeps `ours` unchanged. It returns `ok`, `gone`, or `edited`. It does not overwrite a manually edited block.

## Accepting

`diff-block-accept!` keeps the proposal. It removes the source text, the diff block, and the separating blank line. It inserts the accepted text at the original source position. It then releases the overlays and clears the mark.

If the current state is `theirs`, it accepts the visible block body. In other states, it accepts the stored proposed text.

## Rejecting

`diff-block-reject!` removes the diff block and preserves the original text. It also removes the block's separating blank line. If the rendered block has been edited, it refuses to remove it. This prevents manual edits from being discarded.

## Commands and default keys

| Command | Default key | Action |
|---|---|---|
| `diff-block-accept` | `C-c y` | Keep the proposed text. |
| `diff-block-reject` | `C-c k` | Remove the proposal and keep the original text. |
| `diff-block-cycle` | `C-c d` | Change the display state. |

The key list is a preference. The fence records the key that the buffer keymap assigns to each command at land time.

A plain ` ```diff ` fence pasted from another source has only normal `diff` painting. It is not a pending diff block and has no accept, reject, or cycle record.

## Scheme variables

### `diff-block--format`

The internal block format marker. Its value is `diff-block-1`. `diff-block-pending` uses it to reject incompatible buffer-local data.

### `diff-block--keys`

The default command bindings:

```scheme
'(("C-c y" "diff-block-accept")
  ("C-c k" "diff-block-reject")
  ("C-c d" "diff-block-cycle"))
```

The variable supplies the bindings when the block installs its commands. The fence displays the effective key from the buffer keymap.

### `diff-block-parent-package`

Saves the loader's package context while this file loads. The file restores the context after its definitions.

### `diff-block-parent-namespace`

Saves the loader's namespace context while this file loads. The file restores the context after its definitions.

### `diff-block-parent-domain`

Saves the catalog domain context while this file loads. The file restores the context after its definitions.

### `diff-block-parent-effects`

Saves the catalog effects context while this file loads. The file restores the context after its definitions.

The buffer-local variable named `diff-block` holds the pending block record. `diff-block-pending` validates and returns that record. The record contains the source range, block range, tail, original text, proposed text, note, state, and format marker.

## Scheme API

The public programmatic functions are:

- `diff-block-propose!` creates a pending proposal.
- `diff-block-pending` returns the validated pending record, or false.

The main internal functions manage state, rendering, overlays, and cleanup:

- `diff-block-update!` refines a proposal;
- `diff-block-set-state!` selects a display state;
- `diff-block-cycle!` selects the next state;
- `diff-block-accept!` commits the proposal; and
- `diff-block-reject!` removes the proposal.

## Design properties

The block acts as a temporary review transaction:

1. It captures the original text.
2. It inserts a reviewable proposal.
3. It lets the user inspect alternate views.
4. It detects stale source text before insertion.
5. It preserves a block that the user edits manually.
6. It commits or removes the proposal.
7. It releases overlays and stored metadata.
