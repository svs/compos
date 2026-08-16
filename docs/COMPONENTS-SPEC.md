# UI COMPONENTS — a named, namespaced vocabulary for building views

Written 2026-08-16 (rewritten same day: "components" means UI components,
not a general symbol catalog). Audience: a coding agent (or human) with NO
prior context. Verify every name against the live editor
(`nc -U ~/.aimax/sock`, see SIMPLIFY-SPEC.md Part 0) before you touch
code.

Implementation note, 2026-08-16: the registry, starter vocabulary, gallery,
package/namespace stamps, and catalog integration have landed. The live main
`apropos` is authoritative; `apropos-components` is a `kind=component`
convenience filter rather than a separate search implementation. The durable
agent-facing contract is `COMPONENTS.md`. Retrofitting the existing hand-built
views remains incremental work.

## Part 1: What exists, and the gap

### Exists (LANDED)

- **The block renderer.** A buffer in `render-mode "blocks"` draws the
  `render-blocks` buffer-local: a tree of plists —
  `(tag CLASS 'text/'segs/'children/'anchor/'click/'lines/'mark ...)`.
  The client (editor_live.ex "one renderer for block trees") knows no
  domain words; every class and every string is chosen in Scheme.
- **Hand-rolled block builders in every mode.** diff-mode builds cards,
  section headers, hunk folds (`diff--card-block`, `diff--hunks-block`);
  the agent transcript builds its own cards; list-mode builds rows. Each
  invented its shapes alone.
- **Interaction hooks.** `block-on-click!` routes a block's `'click` id
  back to the owning mode. `'lines` + `'mark` highlight the block while
  point is inside its range. `'anchor` names a scroll target.

### The gap

1. There is no component. Every mode writes raw block plists. The same
   ideas — card with a fold caret, header row, badge, key/value row,
   empty-state notice — are re-invented per mode with per-mode class
   names and small inconsistencies.
2. There is no discovery. The resident builds most new views. Before it
   can REUSE a card, it must find one, and today the only way is reading
   another mode's source. So it re-invents, and the UI drifts.
3. There is no namespace. Nothing says which package owns a shape or a
   class name, so nothing can list a package's UI or retire it cleanly.

### Why this is load-bearing (2026-08-16 discussion)

The platform thesis is "the resident writes the apps" (spotify.scm,
app_server, the ATS recipe). Apps need views; views need parts. A
component catalog with apropos is what makes machine-written UI converge
instead of sprawl — the catalog-first rule: search, reuse, only then
invent. It is also the self-evidence rule applied to the UI: the system
can show, live, every shape it knows how to draw.

## Part 2: The design

### U1. `defcomponent` — a named builder over the block system

```scheme
(defcomponent 'card
  "A foldable card: header row, optional body, click to toggle."
  '(props (title   "header text")
          (open?   "body visible")
          (click   "id handed to block-on-click!")
          (body    "block tree drawn when open"))
  '(example (title "A card" open? #t body ((tag "div" text "hello"))))
  (lambda (p)
    (list 'tag "div" 'class "c-card"
          'children (list ...))))
```

- A component is a pure function: props plist in, block tree out. No
  state — fold state, selection, data all arrive as props from the
  mode's buffer-locals, same as diff-mode does today.
- `(component 'ui/card PROPS)` instantiates one inside any block tree,
  so components nest.
- Registry entry: `(NS NAME DOC PROPS EXAMPLE FN)`. The namespace is
  stamped from the loading package (`*loading-package*`, default
  `'user`; `editor.scm` and core packages stamp `ui`). Globals stay
  flat; `ui/card` is the catalog's display form, not interpreter syntax.
- Class discipline: a component's classes start with its namespace
  (`c-` reserved for `ui/`). The client stays domain-blind; CSS for the
  `ui/` set lives with the client theme. A package that ships its own
  classes ships its own CSS — verify how per-buffer styles reach the
  client before deciding that mechanism (one primitive at most).

### U2. components in the one `apropos` catalog

```scheme
(apropos "card" 'kind 'component)
(apropos "" 'kind 'component 'namespace 'diff)
(apropos-components "card")            ; convenience wrapper
```

Returns entries with qualified name, namespace, package, doc, props, example,
and effects. `M-x apropos-components` opens the same help view prefiltered to
components. This is part of the LLM tool surface with the standing instruction:
catalog first, invention second.

### U3. `M-x component-gallery` — the living storybook

One buffer, blocks render-mode, grouped by namespace: every registered
component DRAWN from its `example` props, with its name, doc, and props
table beside it. The gallery is generated from the registry, so it is
complete by construction and costs nothing to maintain. This is the
demo surface too: "the editor can show you every part it builds UIs
from" is a screenshot that argues the whole thesis.

### U4. The starter set, extracted not invented

Retrofit before inventing. The first components are the shapes the tree
already draws, pulled out of their modes:

- `ui/card` + `ui/fold-head` — from diff-mode's card/caret/hunk trio.
- `ui/section` — the counted section header (diff-mode, ibuffer).
- `ui/row` — list-mode's row with segs and click.
- `ui/kv` — key/value pairs (chat-tool-surface, control-audit will want
  it).
- `ui/empty` — the "nothing to show" notice.
- `ui/badge` — short status chip (status column in list views).

diff-mode and one list-mode view convert to prove the props are right;
the agent transcript stays as-is until the set stabilizes (its renderer
is hot and cached per block).

### U5. Scope fence

Block-mode components only. App-mode documents (app_server) are HTML in
another origin and bring their own component world; exporting `ui/*` as
HTML for apps is a later spec, not this one. CONTROL-SPEC and this spec
touch the same registries nowhere — they compose by both feeding
list-mode views (`control-audit` renders with `ui/row`, `ui/kv`).

## Part 3: Tests (KeyDispatch path, per house rule)

- `defcomponent` + `component`: a nested instantiation renders the
  expected block tree (pure function test through the session).
- Namespace stamp: a component defined while a package loads carries
  that package's ns; one from init.scm carries `user`.
- `apropos-components`: regex, ns filter, empty-pattern manifest.
- Gallery: opens, groups by ns, every registered example renders
  without error (the gallery doubles as the component smoke test).
- Retrofit: diff-mode's card still folds, clicks, and marks current
  through `handle_key/1` after conversion.

## Order

U1 → U4 (extract while defining; the props come from real uses) →
U2 → U3. U5 is a fence, not work. The load-stamp (`*loading-package*`)
lands with U1 and is shared infrastructure — CONTROL-SPEC's future
needs it too.
