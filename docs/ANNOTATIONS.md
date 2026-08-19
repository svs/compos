# Annotations — design note

Status: design, 2026-08-20. Nothing here is built.

The task is not "build flymake". The task is an annotation vocabulary.
Flymake is the first client of that vocabulary.

## The test

The user can override everything about an annotation from `~/.aimax/init.scm`:

- where it shows (inline, gutter, end of line, echo area, popup, list buffer)
- how it shows (face, underline style, colour)
- what animations and transitions it has
- what JS it speaks

The architecture passes when each override needs no repo edit.

## The test against today's kernel

| Override | Today | Reason |
|---|---|---|
| how it shows | passes | shadow the face; user `define-style!` loads last |
| where, inline ranges | passes | replace the display fn; call `overlay-set!` |
| where: gutter, eol text, popup | fails | an overlay is `(start end face)`; no line class, no virtual text, no DOM attributes |
| animations, transitions | half | the renderer rebuilds spans on each keystroke; a transition never fires; an animation re-fires on each render |
| what JS it speaks | fails | `define-style!` exists; `define-script!` does not; the DOM carries no id or data for JS to find |

Each failure is a missing mechanism, not missing policy.

## The layer split (Scheme, all replaceable)

**Layer 1 — data.** `flymake.scm` owns the backend registry, the schedule
(`on-change!` + `debounce!`), and a buffer-local `diagnostics`.
A diagnostic is `(start end severity message backend)`.
The layer ends with `(run-hooks 'diagnostics-changed-hook)`.
It never calls `overlay-set!`.

**Layer 2 — presentation, one function.** A defcustom `flymake-display-fn`
takes `(BUF DIAGS)` and produces effects. The bundled default paints
overlays, sets an eol hint, and echoes the message at point. The user
replaces the function, or the pieces it is built from: the severity→face
map and the severity→where map. Function replacement in `init.scm` is
the override mechanism. Emacs works the same way.

**Layer 3 — interaction routes to Scheme.** A click or hover on an
annotation fires a Scheme handler, as `block-on-click!` does for blocks.
The default popup is a Scheme function the user redefines. JS is the
escape hatch, not the lane.

## The mechanisms Elixir must grow

Each mechanism is generic. None knows about flymake.

1. **Overlay property bag.** `(overlay-set! BUF TAG ((START END PROPS) ...))`.
   PROPS is a plist: `face`, `id`, `data` (renders as `data-*` attributes),
   `before` and `after` (virtual text spans), `line-class` (a class on the
   `.line` div — the gutter surface), `hover` and `click` (Scheme callback
   routing), `hook` (a client hook name). This copies Emacs overlay
   properties. `adjust_ranges` moves the positions; the props ride along.
2. **Stable DOM identity.** The renderer emits `id` as a persistent DOM id.
   LiveView diffing then keeps the node across re-renders. Without this,
   no CSS or JS can satisfy the transition clause.
3. **`define-script!`.** The JS lane, parallel to `define-style!`. The
   contract is a named client hook with mounted/updated/destroyed. An
   overlay attaches it with the `hook` prop. The boot-id reload ships it,
   on the same lifecycle as styles. No sandbox.
4. **Generic hover event (optional).** Pointer-enter on an annotated span
   sends one debounced event to a Scheme handler.

The echo area, list-mode, `define-style!`, and faces already exist.

## The test, made executable

The architecture passes when each snippet works from `init.scm`:

```scheme
;; where: errors in the gutter, not inline
(set! flymake-display-fn
  (lambda (buf diags)
    (overlay-set! buf 'flymake
      (map (lambda (d) (line-props d 'line-class "gutter-err")) diags))))

;; how: dotted amber, not wavy red
(set-face-attribute! 'diag-error 'decoration "underline dotted #d29a22")

;; animation: fade in once, stable across keystrokes
(define-style! "my-diag" ".f-diag-error{animation:fade .3s ease-in}")

;; js: a custom popup that speaks the user's JS
(define-script! "diag-pop" "export default {mounted(){...}}")
```

## Costs

- The hot render path pays for props. Render `data-*` and `id` only on the
  first segment of a range. Keep the 400-range line cap.
- Overlays with props are runtime state. On restore, the display fn re-runs
  from the `diagnostics` buffer-local. This keeps the survive-reload rule.

## Payoff

The same vocabulary serves LSP hover, git blame, agent edit-attribution,
and occur highlights. One annotation layer, many clients. Flymake is the
first client and the test suite.
