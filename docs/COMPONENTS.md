# UI components

This is the contract for agents building compos block-mode views. The live
catalog is authoritative; this file explains how to choose from it.

## Choose before inventing

1. Search by intended behaviour, not by guessed component name:

   ```scheme
   (apropos "foldable heading" 'kind 'component)
   ```

2. Inspect promising results. Apropos includes the qualified name, owner,
   props, example, and constructor. For one component use:

   ```scheme
   (describe-component 'ui/card)
   ```

3. Compose existing components. Instantiate them with:

   ```scheme
   (component 'ui/card '(title "Changes" open? #t body (...)))
   ```

4. Define a new component only when the catalog has no suitable primitive.
   Extract it from a real view, give it a complete example, and verify the
   example in `M-x component-gallery`.

Components are pure functions from a props plist to one renderer block.
Selection, folds, data, and click handling remain in the owning mode and enter
the component through props.

## Starter vocabulary

- `ui/card` — bordered container with optional fold heading and body
- `ui/fold-head` — disclosure caret, title, optional badge and click id
- `ui/section` — section title with optional count
- `ui/row` — selectable text or segmented row
- `ui/kv` — compact key/value details
- `ui/empty` — empty-state notice
- `ui/badge` — short status chip

Use `(apropos "" 'kind 'component)` for the complete current inventory.

## Authoring

```scheme
(defcomponent 'my-package/notice
  "A brief notice with a severity badge."
  '((text string required) (severity string optional))
  '(text "Saved" severity "success")
  (lambda (props) ...))
```

- Use a qualified `namespace/name`.
- Declare required and optional props.
- Include an example that renders without application state.
- Use classes owned by the namespace. `c-` is reserved for `ui/*`.
- Prefer a small composable primitive to a domain-specific page component.
- Do not use these block components for app-mode HTML documents.

## Safety and discovery metadata

Components have the `pure` effect. Commands attached to their click ids carry
their own effects. The shared catalog separates:

- `package`: who owns and replaces an entry
- `namespace`: its stable public vocabulary
- `domain`: the subject area it concerns
- `effects`: `pure`, `read`, `write`, `destroy`, `spend`, `execute`, `external`, `display`

`display` marks operations that change visible buffers, focus, point, mark, or scroll state.

Search these facets with `apropos`; `apropos-components` is only a convenience
wrapper for `kind=component`.
