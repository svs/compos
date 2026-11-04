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
- `ui/tabs` — one row of choices over the same view, current one marked
- `ui/actions` — a row of clickable actions with their keys
- `ui/kv` — compact key/value details
- `ui/keymap` — responsive keycaps and action labels, using theme fonts and colors; optional third column text describes the action
- `ui/keys-bar` — the keys bar of a list-mode buffer: main keys, `? all N`, and an expanded grid per keymap
- `ui/group` — a labelled grouping of related blocks
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

A buffer can pin component blocks below its content with `footer-line-blocks`.
A list mode that declares a `footer` function gets the shared `ui/keys-bar`
footer. The `footer` function supplies `(KEY LABEL)` pairs.

## Components in chat

Chat components are not a separate kind. They are ordinary `defcomponent`s that a chat reply is allowed to draw. A reply names one with a fence whose info is `component NAME` and whose body is the props as Scheme data:

````
```component calendar/event
(title "Interview: Priya × Emergent" start "2026-10-20 15:00" end "15:45" link "https://meet.google.com/abc-defg-hij")
```
````

The chat view (`chat-view-block` in `agent-transcript.scm`) splits the reply around such fences and draws each with `(component NAME PROPS)`. The props are read, never evaluated. A fence nested inside another fence, or one still streaming, stays text.

### Prop docstrings

A prop is `(name type required-or-optional [DOC])`. The optional fourth element documents the prop for people and models:

```scheme
(defcomponent 'calendar/event
  "One calendar entry: a date leaf, the title, the time, where, who."
  '((title string required "what the meeting is, as the invite names it")
    (start string required "local date-time, \"2026-10-20 15:00\"")
    (end   string optional "time only when it's the same day, \"15:45\""))
  '(title "Interview" start "2026-10-20 15:00" end "15:45")
  (lambda (props) ...))
```

`(describe-component 'NAME)` shows the props with their docs and the example.

### Allowing a component in chat

The package that owns a component opts it in with `(component-chat! 'NAME)`. Only components whose props are plain data qualify; one that takes `blocks` or `any` is refused. `(chat-components)` lists the allowed ones as `(NAME DOC)`, and `(component-chat? 'NAME)` asks about one.

A component lives in the package that owns its mode: `calendar/event` in `calendar.scm`, `ats/candidate` in `ats.scm`. The generic `ui/*` ones (stat, stats, table, kv, chips, badge, quote, chart) stay in `components.scm`. A component exists only while its package is loaded.

### Checking

In chat, props are checked strictly: `(component-check 'NAME PROPS)` lists unknown props, wrong types and missing required ones, and answers `()` when they fit. A fence that fails, or names a component chat does not allow, draws an error card with the problems and the raw props. The model gets a one-line note about the failed fences on its next turn. Outside chat, `component` still checks only required props.

### Actions

A reply supplies data only; it never names a command. The component declares its actions in code with `component-actions!`, each as `(NAME LABEL KEY EFFECTS FN)`, the default first. FN gets the fence's props:

```scheme
(component-actions! 'ats/candidate
  (list (list 'open "Open" "o" '(display external)
              (lambda (p)
                (display-buffer-other-window!
                  (ats-candidate-show! (component--get p 'id) (component--get p 'name #f) #t))))))
```

An action whose effects go beyond `pure`, `read`, `display` and `external` (so `write`, `destroy`, `spend`, `execute`) asks y/n before it runs. A fence that failed its check has its actions turned off. `(component-actions 'NAME)` lists a component's actions.

Reuse the mode's own row actions where they exist, so a card in chat and a row in its list do the same thing.

### Keys

- Click a button on the card.
- `M-<up>` / `M-<down>` step through the chat's blocks; a selected component gets an outline.
- `M-RET` runs the selected component's default action.
- `C-c C-o` opens a menu of all its actions.
- With nothing selected, `M-RET` and `C-c C-o` act on the newest component.

No component takes focus. Drawing never moves focus, point or scroll, and actions that show something use the other window.

### The prompt

`apps/compos_core/priv/prompts/components.md` tells the model the fence exists and to check props with `describe-component` and `component-check` before writing one. See `docs/PROMPTS.md` before changing it.
