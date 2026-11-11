# Group modes

A group mode is a major mode for a group. A buffer wears a major mode, and
the mode decides its keys, faces, and behaviour. A group wears a group mode,
and the mode decides its language model, its window layout, and its theme.

The stock modes are `coding`, `writing`, `browsing`, and `chat`. A user adds
a mode in `init.scm` with one form. Elixir does not know that group modes
exist, except for one late mechanism (per-frame faces, see Phase 5).

This document is the specification. It has the model, the rules, the
implementation contract, the phases, and the acceptance list. Read
`docs/groups.md` first: a group mode changes nothing written there.

## Model

### Objects

- A **group mode** is a named record in the registry `*group-modes*`. It
  has these facets:
  - `llm`: the name of an LLM bundle (see `*llm-bundles*`), or `#f`.
  - `layout`: a layout spec (see Layout), or `#f`.
  - `theme`: a theme name, or `#f`.
  - `setup`: a fn called with the group id when a frame enters the group.
  - `teardown`: a fn called with the group id when a frame leaves the group.
  - `doc`: one sentence for the catalog and the chooser.
- A **group** carries one mode name in its record (field `mode`), and one
  **settings** plist (field `settings`). The settings plist holds the facets
  the user changed for this group only. A group with no mode wears
  `group-mode-default`.
- A facet **resolves** in this order:

  ```
  group settings  ->  group mode  ->  global default
  ```

  The global default is the value the editor has today: the default
  connector and model, the autolayout customs, `*current-theme*`.

- **Drift** is the state where a group's settings differ from its mode. The
  modeline shows drift. Two commands end it: `group-mode-save` writes the
  settings into the mode, `group-mode-revert` clears the settings.

### Naming

- The registry is `*group-modes*`. A mode name is a short lowercase word:
  `coding`, `writing`. It is not a buffer mode name, so it has no `-mode`
  suffix. The hook is `NAME-group-mode-hook`.
- `(define-group-mode NAME &rest FACETS)` defines or redefines a mode. It
  registers the mode in the catalog under kind `group-mode`, and it makes
  the M-x command `group-mode-NAME`, which puts the current group in NAME.
- `(group-mode G)` returns the resolved mode name. `(group-mode-set! G
  NAME)` writes the record and runs the enter path on every frame that
  shows G.
- `(group-facet G KEY)` returns the resolved value of one facet.
  `(group-setting-set! G KEY VALUE)` writes one group-only override.

## Rules

### Enter and leave

1. `switch-to-group!` is the one door. It runs `group-mode-leave!` for the
   frame's old group, then `group-mode-enter!` for the new one, then
   `(run-hooks 'group-switch-hook)`. The hook takes no arguments;
   `*group-switched*` holds `(FROM TO)`.
2. Enter applies the theme facet when it is not `#f` (Theme). It runs the
   mode's `setup` fn, then `NAME-group-mode-hook`.
3. Enter never rearranges a saved layout. The layout facet is used when the
   group has no saved layout for this frame, and when the user runs
   `group-mode-reset-layout`. This keeps the rule in `docs/groups.md`: the
   layout the user left is the layout that comes back.
4. Leave runs the `teardown` fn. It does not change the theme: the next
   group's enter does, or the global theme returns when the next group's
   theme facet is `#f`.
5. `group-mode-set!` on the group a frame shows runs leave for the old mode
   and enter for the new one on that frame. It runs `group-mode-reset-layout`
   only when the user asks (`C-u` prefix, or the `group-mode` chooser's
   "and re-tile" answer).

### LLM

6. The `llm` facet names a bundle or is one (a bundle plist). Unset, a
   new chat takes `llm-default-bundle`. The whole bundle applies: connector,
   model, effort, presets, permission stance, agent mode, prompt sections.
   A group mode does not invent a second record of LLM settings.
7. `group-chat-init!` applies the resolved bundle to a group chat when it
   creates the chat. The chat records `'llm-scope 'group`.
8. `C-c b` (`llm-configure`) gains a scope selector, key `g`, with the
   values `global`, `group`, `buffer`. The header names the scope. RET
   applies the bundle at that scope:
   - `buffer`: today's behaviour (`llm-bundle-apply!`), and sets
     `'llm-scope 'buffer` on the session buffer. The chat is pinned.
   - `group`: `(group-config-set! G 'llm NAME)` writes it into the group's
     `group.scm`, then re-applies the bundle
     to every chat of G whose `llm-scope` is not `buffer`.
   - `global`: sets `llm-default-bundle` (a new defcustom), then re-applies
     to every chat whose `llm-scope` is `#f`.
9. A chat that a user reconfigured by hand (a model pick, not a bundle) is
   off-bundle. `llm-configure` shows "off-bundle" in the header, and RET on
   `.` (fine-tune) keeps that state. `s` saves it as a bundle, as today.
10. `workspace--llm-defaults-from` in `worktrees.scm` becomes a bundle read
    through the same chain, and the `workspace-llm-defaults` buffer-local
    goes away.

### Layout

11. A layout spec is one of:
    - `(autolayout SIDE RATIO STACK)`: the StumpWM tiler in `layouts.scm`.
      Enter turns `autolayout-mode` on for the frame with those parameters;
      leave turns it off when the next group's spec is not `autolayout`.
    - `(DIR RATIO PANE PANE ...)`: the `define-mode-layout!` engine. A PANE is
      `main` (the group's first work buffer by MRU), `chat` (the group chat),
      `scratch` (the group scratch), `"NAME"`, or `(ensure "NAME" "COMMAND")`.
      The engine drops a pane that names no member: a layout never brings a
      foreign buffer into the group (docs/groups.md, sealed groups).
    - a fn of the group id, for a user who wants code.
12. The autolayout customs `window-layout-main-side`, `-main-ratio`, and
    `-stack` stay the global defaults. `autolayout--algorithm` reads the
    frame's group facets first.
13. `group-default-layout!` reads the layout facet. Its current body (main
    left, side right at 0.6) becomes the layout of the `coding` mode.

### Theme

14. The `theme` facet is a theme name. Enter calls `theme-apply!`, never
    `load-theme`: a group theme is not persisted as the editor theme.
    `theme.scm` keeps the theme the user chose with `load-theme`, and that
    theme returns when a frame enters a group whose theme facet is `#f`.
15. Faces are one table in `Compos.Core.Editor`, shared by every frame. In
    Phases 1-4 the theme follows the frame that switched last. Two frames on
    two groups with two themes show the same faces. Phase 5 fixes this with
    per-frame face tables (see Phases). Until then the modeline of a frame
    whose group theme is not on screen shows the theme name in a `shadow`
    face.

### Choice of mode

16. `group-new` gives a new group the mode that `group-mode-guess` returns.
    `group-mode-guess` is a defcustom that holds a fn of the group id. The
    stock fn answers `writing` when the seed buffers are prose files
    (`.md`, `.org`, `.morg`, `.txt`), `browsing` when they are `*browse:*`
    buffers, `chat` when the only member is a chat, and
    `group-mode-default` otherwise. `group-mode-default` is `"coding"`.
17. `M-x group-mode` opens a completing prompt over the registry for the
    current group. The switcher (`C-c g`) shows the mode after the name.
18. `group-revive!` restores the mode and the settings with the record.

### Persistence

19. The group record grows two fields, `mode` (index 9) and `settings`
    (index 10). `group-record-colors-restore` carries them. A record from an
    older desktop has neither; the reader treats a missing field as `#f`.
20. The registry is not persisted. Modes come from `init.scm` and from the
    stock package. `group-mode-save` writes into `*group-mode-overrides*`,
    a persist-global plist keyed by mode name, and `define-group-mode`
    merges the override on top of the definition. This is the bundle rule:
    code defines, the desktop remembers what the user changed.

### Stock modes

```scheme
(define-group-mode "coding"
  'llm "pair"
  'layout '(autolayout left 0.62 column)
  'doc "One main pane on the left, the rest stacked; the pair bundle")

(define-group-mode "writing"
  'llm "draft"
  'layout (list 'h *window-third* 'main 'scratch 'chat)
  'theme "paper"
  'setup writing-group-setup!     ; writing-mode on the member documents
  'doc "Document, scratch, chat side by side; prose typography")

(define-group-mode "browsing"
  'llm "cheap"
  'layout '(h 0.7 main chat)
  'doc "A reader with the chat beside it; a cheap read-only model")

(define-group-mode "chat"
  'llm "chat"
  'layout 'chat
  'doc "One chat, full frame")
```

The bundle names `pair`, `draft`, `cheap`, and `chat` ship as stock bundles
in `*llm-bundles*` when the user has not defined them. A facet that names a
bundle the user deleted resolves to the global default and the modeline
shows drift.

`writing-layout` (the minor mode in `writing.scm`) becomes the `writing`
group mode. `M-x write` stays: it puts the current group in `writing` and
shows the document. `writing-mode` (the buffer minor mode) stays as it is.

## Implementation contract

- `apps/compos_core/priv/packages/group-modes.scm`, loaded after
  `groups.scm`, `layouts.scm`, and `themes.scm` in `init.scm`. Stock modes
  live at the end of the same file. `writing.scm` registers the writing
  setup fn and loads after it.
- `groups.scm` changes: two record fields, `group-mode`, `group-mode-set!`,
  `group-facet`, `group-setting-set!`, the leave/enter calls in
  `switch-to-group!`, `group-switch-hook`, `group-default-layout!` reads the
  facet, `group-new` calls `group-mode-guess`, the switcher and modeline
  show the mode.
- `editor.scm` changes: `llm-default-bundle` defcustom, the resolution chain
  in `llm-config-core` (buffer local -> group facet -> global), `'llm-scope`
  joins `chat-identity-locals`.
- `transient.scm` changes: the scope selector `g`, the header, RET by scope.
- `layouts.scm` changes: `autolayout--algorithm` reads frame group facets;
  `group-mode-reset-layout`.
- `themes.scm`: no change. Phase 5 adds `(theme-apply! NAME FRAME)`.
- Every public definition carries `domain!` and `effects!`.
- Tests in `priv/tests/group-mode-test.scm`: a dummy mode, a dummy bundle,
  a dummy theme made with `define-theme`, dummy keys under `<f9>`. No test
  names a production mode's facets or a production binding.

## Phases

1. **Record and registry.** Fields, `define-group-mode`, `group-mode`,
   `group-mode-set!`, `group-facet`, chooser, modeline, persistence, the
   enter/leave path with theme and setup/teardown, `group-switch-hook`.
2. **LLM.** Resolution chain, `group-chat-init!` applies, `llm-scope`,
   the transient scope selector, drift in the header, `workspace--llm-defaults`
   retired.
3. **Layout.** Layout specs, `group-default-layout!` reads the facet,
   autolayout facets per group, `group-mode-reset-layout`.
4. **Stock modes and migration.** The four modes, the four bundles,
   `group-mode-guess`, `writing-layout` folded into `writing`,
   `docs/groups.md` cross-reference, `docs/COMPONENTS.md` for the chooser.
5. **Per-frame faces.** Elixir mechanism: `Editor` keeps a face override
   map per frame; `set_face(name, attrs, frame)` and `clear_face(name,
   frame)`; the frame payload merges its overrides over the global table
   before `FaceCSS.css`. Scheme: `(theme-apply! NAME FRAME)`. Only after
   Phases 1-4 are in use.

## Acceptance

1. `(define-group-mode "t" ...)` registers a mode; `(group-mode-names)` lists it;
   `M-x group-mode-t` exists.
2. A new group wears the mode `group-mode-guess` returns; a group with no
   mode resolves to `group-mode-default`.
3. `switch-to-group!` into a group whose mode names a theme puts that
   theme's faces on screen and leaves `theme.scm` unchanged. A switch into a
   group with theme `#f` puts the user's theme back.
4. The setup fn runs once per enter with the group id; the teardown fn
   runs once per leave; `group-switch-hook` runs after both with
   `*group-switched*` set.
5. The group chat created for a group gets the mode's bundle: connector,
   model, effort, presets, permission, agent mode. Its `llm-scope` is `group`.
6. A bundle applied at buffer scope pins the chat; a later group-scope
   apply changes the other chats and not the pinned one.
7. A group-scope apply writes the group's settings; the modeline shows drift;
   `group-mode-revert` clears it; `group-mode-save` writes it into the mode
   and the override survives a desktop round-trip.
8. First entry into a group with no saved layout uses the mode's layout
   spec; re-entry uses the saved layout; `group-mode-reset-layout` uses the
   spec again.
9. An autolayout spec turns `autolayout-mode` on with the spec's side,
   ratio, and stack for that frame; a switch to a group with a pane spec
   turns it off.
10. A pane that names a non-member is dropped.
11. A record from a desktop written before this change restores with mode
    `#f` and settings `'()`.
12. `group-revive!` restores mode and settings.
