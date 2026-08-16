# Editor substance — build order

1. **Filename completion** — TAB in find-file; completion fn is Scheme (`file-complete`), core adds `list-dir` + on-complete closure support ← *in progress*
2. **Marks & regions** — `C-SPC` set-mark, region primitives, `C-w`/`M-w` kill/copy-region. Prereq for pipes.
3. **isearch** — `C-s`/`C-r` incremental search with highlight, wrap, `RET`/`C-g`.
4. **Shell buffers (comint)** — PTY via erlexec, output streams into buffer, `RET` sends line, `M-x shell`. Process filters feed the reactor.
5. **dired** — written entirely in editor.scm (the extensibility bar): `list-dir` + read-only buffers + buffer-local keymaps + line→file mapping. `RET` visits, `d`/`x` delete, `+` mkdir.
6. **Theming** — `(set-face-attribute ...)` → face registry → CSS custom properties pushed live; themes are `.scm` files.
7. **LLM primitive + gptel pipes** — async streaming `(llm ...)`; `M-|` pushes region through Scheme/shell/LLM transformers; composition is pure Scheme.
8. **Copilot completions** — ghost-text overlays + debounced change hook + same `llm` primitive; TAB accepts.
9. **Tree-sitter NIF** — Rustler; highlighting via scopes→faces, `ts-query`, `{:ts_query,...}` reactor matchers, zero-leak agent context.
10. **Viewport windowing** — send only visible lines + scroll state to the frontend (the display-list protocol); big-file safety.

Then: undo grouping, per-window points, MCP server, agent runtime (`define-agent`, flows, human gates), packaging (mix release + native shell).
