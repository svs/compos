# Org-mode for ai-max.el

## Context

Goal: make `.org` files first-class — outline folding, headline fontification, TODO cycling, structure editing — with org-mode itself written in userland Scheme (per the "Scheme is the brain" commitment; `dired.scm` is the reference mode). Exploration of all three layers (core, Scheme userland, rendering) shows the mode-definition machinery is ready (`define-mode`, `*auto-mode-alist*`, per-buffer keymaps, `define-command`), but four core capabilities org needs don't exist at any layer:

1. **No text properties/overlays** — Scheme cannot attach a face to a text range. Faces are a global theme registry only. (`seg_build` in `editor_live.ex:300` already accepts an arbitrary `[{start, end, class}]` overlay list — it's the designed-for insertion point, currently fed only cursor/region.)
2. **No folding/invisibility** — the viewport is a raw `Enum.slice` (`editor_live.ex:98`); all scroll/cursor math is logical-line based (`editor.ex:632-671`).
3. **No regex, no date/time, weak arithmetic in the Scheme** — interpreter has no `cond`/`let*`/`when`, no `modulo`, no forward `string-index`; org parsing/timestamps/agenda are blocked.
4. **No after-change hook reachable from Scheme, and no Shift modifier in the key pipeline** — self-insert bypasses Scheme entirely (`key_dispatch.ex:190`), so typing can never trigger refontification; `S-TAB` is unbindable (`layouts.ex` `keySpec`).

Tree-sitter-org was considered and **rejected**: scope names are truncated at the first `.` (`native/aimax_ts/src/lib.rs:50-54`) which collapses `title.1..6` into one scope, it needs a vendored grammar + Rust rebuild, and folding needs a Scheme outline model anyway. Regex-based fontification via overlays instead.

## Phase 0 — core primitives (Elixir)

### 0.1 Overlays
`apps/aimax_core/lib/aimax/core/buffer.ex`:
- defstruct adds `overlays: %{}` (tag → `[{start, end, face}]`), `overlay_gen: 0`.
- API: `set_overlays(name, tag, ranges)` (replace-per-tag, bump gen), `clear_overlays(name, tag \\ :all)`, `overlays(name)` (flat list), `overlay_gen(name)`.
- In `do_insert/4` / `do_delete/4` (`buffer.ex:313-351`): map overlay endpoints through the existing `adjust_insert/adjust_delete` (`buffer.ex:374-383`), same as mark. Not snapshotted into undo history — desync heals via recompute (0.7).

`scheme_api.ex`: `(overlay-set! buf tag ranges)` where ranges = list of `(start end face-name)`, `(overlay-clear! buf tag)`, `(buffer-overlays buf)`.

Render pipeline:
- `editor.ex` `render_walk` leaf clause (`:632-668`): add `overlays` + `overlay_gen` to the rendered leaf.
- `editor_live.ex` `decorate/2` (`:88-101`): cache key becomes `{buffer, version, ts_lang, overlay_gen}`.
- `build_static/1` (`:105-135`): bucket overlays per line as `line.ov` (classes `"f-" <> face`), pass as 4th arg to `seg_build` (currently `[]` at `:132`).
- `render_pass/4` (`:255-296`): touched lines get `line.ov ++ [region/cursor]` so the cursor line keeps org faces.
- `face_css/1` (`:354-361`): besides CSS custom props, emit a `.f-NAME { color: var(--NAME-fg, inherit); background: var(--NAME-bg, transparent); font-weight/style/decoration via vars }` rule per registered face → **new faces become pure Scheme, no `layouts.ex` edits per face**.

### 0.2 Folding
Hidden **byte ranges** stored in Buffer, auto-adjusted like mark; converted to hidden-line sets at render time. (Dired-style buffer regeneration rejected: org buffers are real file buffers — regeneration breaks editing/saving/undo/point.)

- `buffer.ex`: defstruct `hidden: []` (`{start, end}` ranges = folded subtree bodies); `set_hidden/2`, `hidden/1`; adjust in `do_insert/do_delete`. `next_line/prev_line` motions loop past hidden ranges so the cursor never lands in a fold (`goto-char!` stays unclamped; org commands reveal-before-move).
- `scheme_api.ex`: `(buffer-set-hidden! buf ranges)`, `(buffer-hidden buf)`.
- `editor.ex` `render_walk` leaf (`:632-668`): compute `hidden_lines` MapSet from ranges + text; `total_lines` and `cursor_line` become **visible-line** based so top clamp/auto-follow (`:640-648`) and modeline `pct` work unchanged; add `hidden_lines` to the leaf.
- `editor_live.ex` `decorate` (`:98`): `static |> Enum.reject(hidden) |> Enum.slice(top, rows + 4)`. Static cache unaffected (hiding only filters the slice). Line numbers keep logical `num` (gaps, like Emacs). Optional: `" …"` fold-marker seg on lines whose successor is hidden.

### 0.3 Regex builtins (`apps/aimax_scheme/lib/aimax/scheme/builtins.ex`)
Over Elixir `Regex`, compiled-pattern cache in `:persistent_term`, **byte offsets** (compose with point/overlays/`buffer-substring`):
`(re-match? pat s)`, `(re-match pat s)` → groups or `#f`, `(re-find pat s start)` → `(mstart mend)` or `#f`, `(re-find* pat s)`, `(re-groups pat s start)` → per-group `(gstart gend)`, `(re-replace pat s repl)`, `(re-replace-all pat s repl)`.

### 0.4 Time builtins (builtins.ex)
`(current-time)` epoch secs, `(time->parts secs)` → `(y m d h min dow)`, `(parts->time y m d h min)`, `(format-time secs fmt)` (`Calendar.strftime` — `"%Y-%m-%d %a"` covers `<2026-08-06 Wed>`), `(time+ secs days)`.

### 0.5 Interpreter niceties (all cheap; org.scm is unwritable without the first group)
- `eval.ex`: `cond` (with `else`), `when`, `unless`, `let*`. No quasiquote/macros.
- `builtins.ex`: `modulo quotient min max abs member string-index` (forward, byte), `string-upcase string-downcase string-trim string-repeat`, **`substring-bytes` + `string-byte-length`** (binary_part-based), `sort` (natural order only — comparator closures can't thread the store; sort `(key . item)` pairs).
- Prelude (`scheme.ex:17-35`): `assq remove list-index iota`.

### 0.6 Shift modifier (~3 lines)
`layouts.ex` `keySpec`: prefix `S-` for shifted **named** keys only (TAB, arrows, RET — printable chars already encode shift). Key seqs are opaque strings server-side; zero other changes. Unlocks `S-TAB`, `S-<up>`, `M-S-<left>`…

### 0.7 After-change hook for Scheme (required, not deferrable — self-insert never touches Scheme)
`session.ex` primitives: `(on-change! buf fn)` → rule id, `(remove-on-change! id)`. Wraps existing `Reactor.on_change` (`reactor.ex:31`) with `debounce: 30, sources: :all`; handler called back into Session after the triggering eval returns (Reactor handlers run in Tasks — no deadlock). Loop guard: hook edits use `:editor`-source primitives (`buffer-insert!` etc.) and the org handler refontifies on all sources but only *acts* (cookie updates) on non-editor sources. `:undo`-sourced events are what heal fold/overlay desync.

## Phase 1 — `apps/aimax_core/priv/org.scm` (userland MVP)

- **Load order** (`session.ex:113`): `editor.scm, dired.scm, org.scm, themes.scm`.
- **auto-mode**: edit `editor.scm:62` in place — `(".org" "text-mode")` → `(".org" "org-mode")` (`auto-mode` applies *every* matching entry, so the stale entry can't just be shadowed).
- **Mode setup** (dired pattern): `define-mode "org-mode"` → install local keys per buffer, register `on-change!` once (guard via buffer-local `org-hook-id`), initial `org-refontify!`.
- **Fold state**: buffer-local `'org-folds` = folded-headline byte offsets (Scheme owns it; Buffer `hidden` ranges are derived via `org-apply-folds!`). Re-anchored/validated in the change handler (drop folds whose line no longer matches `^\*+ `) — this is also the undo self-heal.
- **Keymap**: `TAB` org-cycle, `S-TAB` org-global-cycle (overview↔show-all), `C-c C-t` org-todo, `M-RET` new headline, `C-RET` heading-after-subtree, `M-<left>/<right>` promote/demote (`M-S-` = subtree), `M-<up>/<down>` move subtree, `S-<up>/<down>` priority, `C-c C-c` checkbox toggle + `[n/m]`/`[p%]` cookie recount.
- **Parsing**: pure Scheme over `(split-lines (buffer-text buf))`, recomputed per command; headline = `(re-match "^(\\*+)[ \t]" line)`; subtree extent = scan to next headline with level ≤ current. **All buffer-facing indexes via `string-byte-length`/`substring-bytes`, never grapheme `string-length`.**
- **Fontification**: full-buffer recompute in the debounced change handler + eagerly at the end of each structural command; one `(overlay-set! buf 'org spans)`. Patterns: headline → `org-level-N` (N = 1 + (level-1 mod 4)), `TODO`/`DONE` keyword, `[#A]` priority, `:tag:` tails, `<...>`/`[...]` timestamps, cookies, `- [ ]` checkboxes, `^#\+` meta.
- **Faces**: `org-level-1..4, org-todo, org-done, org-date, org-tag, org-priority, org-checkbox, org-cookie, org-meta, org-fold-marker` via `set-face-attribute!` in org.scm (defaults) + entries in both `themes.scm` palettes. Zero layouts.ex work thanks to 0.1's `face_css` class generation.

## Phase 2 — later
- Timestamps `C-c .` / `C-c C-s` / `C-c C-d` (needs only 0.4): minibuffer date read with `+Nd` shorthand; SCHEDULED/DEADLINE planning line.
- Agenda: dired-style regenerated read-only `*Org Agenda*` — scan org buffers with `re-find*`, sort `(epoch . entry)` pairs, overlay-fontify, `n/p/RET/q/g` keys, RET jumps. Pure userland.
- Tags (`C-c C-q`), links (`C-c C-o`: `[[file:...]]` → `visit`; http needs a trivial `browse-url!` primitive).
- Tables: defer (TAB collision with org-cycle; pure string realign later).

## Risks / edge cases
1. **Byte vs grapheme** is the #1 footgun — codify the `substring-bytes`-only rule in an org.scm header comment; add a UTF-8-headline test fixture.
2. **Undo desync**: undo restores `{rope, point, mark}` only; the `:undo`-sourced change event triggers fold re-validation + refontify (one debounce-tick flash, accepted).
3. **Overlay staleness ≤30 ms** between edit and debounced recompute — cosmetic, accepted.
4. **Cursor in a fold** via `goto-char!`/search: render must tolerate it (treat as nearest visible predecessor); auto-reveal is Phase 2.
5. **on-change reentrancy**: `:editor`-source convention is the only loop guard; keep cookie edits idempotent.

## PR sequence
1. Interpreter special forms + builtins (`eval.ex`, `builtins.ex`, prelude) + torture tests.
2. Regex + time builtins.
3. Overlays end-to-end (buffer → scheme_api → editor.ex → editor_live.ex incl. `face_css` classes). Demo via `M-:`.
4. Folding end-to-end (buffer `hidden` + motion skip → visible-line math → slice filter).
5. `S-` modifier + `on-change!`/`remove-on-change!`.
6. `org.scm` MVP + auto-mode edit + load list + themes.scm faces.
7. Timestamps, agenda, tags/links, tables.

## Verification
- `mix test` throughout; new tests: interpreter torture tests for new forms/builtins; `buffer_test` for overlay/hidden adjustment across insert/delete/undo; an `org_test.exs` driving commands via `Session.eval` + `KeyDispatch` (the `editor_test.exs` pattern).
- Manual: `mix run --no-halt`, open http://localhost:4004, `C-x C-f` a fixture `.org` file → headlines colored, `TAB` folds, `S-TAB` global-cycles, `C-c C-t` cycles TODO, `M-RET`/`M-arrows` structure-edit, checkbox + cookie via `C-c C-c`; then undo-spam and confirm folds/faces heal.
