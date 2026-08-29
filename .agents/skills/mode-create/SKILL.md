---
name: mode-create
description: Design, create, or revise compos editor modes and their Scheme UI. Use for requests to add a major mode, list mode, app buffer, mode-specific commands, keymaps, views, or reusable UI components in compos. Require catalog discovery with apropos and apropos-components before implementation.
---

# Create an compos mode

Build the mode in Scheme. Keep Elixir limited to mechanisms that Scheme cannot supply.

## Discover before designing

1. Read `CLAUDE.md`, `docs/ARCHITECTURE.md`, and `docs/COMPONENTS.md`.
2. Query the live catalog with `(apropos "WORDS")`. Use words that describe the requested behavior.
3. Query `(apropos-components "WORDS")` for each required part of the view.
4. Inspect promising UI parts with `(describe-component 'NAMESPACE/NAME)`.
5. Inspect one similar existing mode and the `define-list-mode!` contract in `priv/editor.scm`.

Do not select a component by name from memory. Record the useful catalog results in the working update.

## Choose the mode shape

- Use `define-list-mode!` for selectable rows, marks, filters, tables, flags, and bulk actions.
- Use `define-mode` for a custom text or block view.
- Use app rendering only when the mode needs an HTML-like interactive document.
- Reuse catalogued components through `(component 'NAMESPACE/NAME PROPS)` when they fit.

Keep selection, state, folds, and click handling in the mode. Pass display data into pure components through props.

## Create missing components

Define a component only when `apropos-components` finds no suitable part.

1. Extract a small reusable part from the real view.
2. Define it with `defcomponent` under a qualified namespace.
3. Give it a short description, a complete prop schema, and a working example.
4. Use namespace-owned classes. Reserve `c-` classes for `ui/*` components.
5. Render its example in `M-x component-gallery` and inspect it through compos.

Do not launch or control Chrome, another browser, or a browser automation stack.
The mode, component gallery, buffers, render state, and key dispatcher are the
verification surface.

Do not create domain-specific page components when existing small components compose cleanly.

## Implement the mode

1. Put commands, keymaps, view policy, and mode setup in the relevant `priv/*.scm` package.
2. Set `domain!` and `effects!` before public definitions, commands, modes, settings, and components.
3. Make the setup function rebuild keys, overlays, and derived content from buffer-local state.
4. Mark derived list content as transient through `define-list-mode!`.
5. Keep sensitive values out of rendered buffers and persistent locals.
6. Add concise mode documentation and a discoverable entry command.

## Verify

1. Add focused tests that drive commands through `KeyDispatch.handle_key/1`.
2. Test opening, interaction, refresh, and desktop restore behavior where applicable.
3. Run the focused tests, then run the full test suite.
4. Open the mode inside compos. Inspect its buffer text, overlays, render state,
   selection, and buffer-local state as applicable.
5. Drive navigation and actions through `KeyDispatch.handle_key/1`. Do not use
   Chrome or external browser automation for compos UI verification.
6. Re-run `apropos` for the new public definitions and components. Confirm their metadata is correct.
