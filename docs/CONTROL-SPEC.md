# CONTROL — groups, bundles, presets, and semantic permissions

Written 2026-08-16. Audience: a coding agent (or human) implementing this
with NO prior context on the repo. Read Part 0 and Part 1 before you touch
code. Nothing here is started unless marked LANDED.

## Part 0: How to work in this repo (read first)

- **The one rule: Elixir supplies mechanism, Scheme decides policy.** This
  spec adds at most ONE Elixir primitive (C3). Everything else is Scheme in
  `apps/aimax_core/priv/packages/*.scm`.
- **Verify every name against the live editor before you use it.** The
  dialect is not Emacs Lisp and not R7RS. Use the socket:

  ```sh
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(filter (lambda (e) (re-match? \"preset\" (car e))) (public-api))"}}' | nc -U ~/.aimax/sock
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(describe-function (quote chat-extra-tool-specs))"}}' | nc -U ~/.aimax/sock
  ```

- **Dev loop**: `mix test`, then restart the daemon to reload `priv/*.scm`
  (see CLAUDE.md). Tests drive the editor through
  `KeyDispatch.handle_key/1`.
- **The three-lists rule**: every new chat buffer-local goes into exactly
  one of `chat-identity-locals`, `chat-conversation-locals`,
  `chat-runtime-locals` in `editor.scm`, in the same commit that adds it.
- svs runs multiple agent sessions in this tree. `git status` before you
  commit. Commit only files you changed.

## Part 1: What exists today, and why it is not enough

### Today (all LANDED, in `packages/mcp.scm` and `packages/agent.scm`)

- `(mcp-register! 'name SPEC)` declares a server. `mcp-resolve-spec` is the
  ONE place a spec resolves its `"@VAR"` key references (keys.scm chain).
- `(define-preset! 'name DESC SERVERS)` names a list of servers. A chat
  holds its choice in the `chat-presets` identity local. `llm-set-preset`
  enables one. `chat-tool-surface` shows the result.
- The api lane reads tool specs fresh at every send
  (`chat-extra-tool-specs`). The ACP lane fixes `mcpServers` at
  session/new; `chat-presets-changed!` marks the chat dirty for reattach.
- `chat-permission-mode` is an identity local on agent chats.

### The gaps

1. A preset grants a whole server. There is no tool-level control. A
   server with one useful read tool also brings its delete tool.
2. Permission control is enumeration. A person must know every tool name
   to write a policy. New tools arrive unclassified and ungoverned.
3. There are no principals. A chat, a sub-agent thread, and a served app
   (`app_server.ex`) all get whatever the buffer's presets say. Nothing
   groups them, and nothing grants by group.
4. Presets do not compose. A preset names servers only — not a model, not
   a prompt fragment, not a permission posture. There are no combos.

### The doctrine (decided; see design-philosophy)

**A permission that is a prompt is theater. A permission that is
reachability is real.** This spec spends its effort on the three real
boundaries, in order of strength:

1. **Mount** — a tool that is not in the chat's surface does not exist.
   Deny means absence, not refusal.
2. **Keys** — a bundle that does not reference a key never resolves it.
   The keys.scm chain is per-sphere; a sphere without the key has no route
   to the secret (see naming-vaac / spheres discussion, 2026-08-16).
3. **Process/origin** — spheres are separate daemons; served apps are
   separate origins (`app_server.ex`).

Confirmation prompts survive only for one narrow class: actions the
category system marks irreversible (Part 2, C3). Everything else is
decided before the model ever sees the tool.

## Part 2: The design

Four layers, each a plain Scheme registry, each one file section in
`packages/mcp.scm` (split into `packages/control.scm` if it grows past
~300 lines):

```
server   →  bundle   →  preset   →  combo
(exists)    (C1)         (C4)        (C4)
                 ↑ groups grant bundles to principals (C5)
                 ↑ categories govern tools inside the mount (C2, C3)
```

### C1. Bundles — servers plus tool filters

```scheme
(define-bundle! 'recruiting
  "Mail, calendar, and ATS reads for hiring work."
  '(servers (gmail gcal ats-ash)
    allow   ("mcp__ats-ash__search_*" "mcp__gmail__*")
    deny    ("mcp__gmail__trash_*" "mcp__ats-ash__delete_*")))
```

- `servers` is the connect list, exactly as presets have today.
- `allow`/`deny` are glob patterns over bridged tool names
  (`mcp__<server>__<tool>`). `deny` wins over `allow`. Absent `allow`
  means "all tools of these servers".
- The filter applies at MOUNT time: `chat-extra-tool-specs` (api lane) and
  the ACP `mcpServers` builder in `agent.scm` both pass their spec list
  through `bundle-filter`. A filtered tool never reaches either lane.
  This is the reachability rule, not a runtime check.
- `define-preset!` stays; a preset that names servers directly keeps
  working (compat shim: a bare server list is an anonymous bundle with no
  filters).

### C2. Categories — the resident classifies every action

The idea (svs, 2026-08-16): "some sort of categorisation of actions —
cheap with LLM. this is intelligence pervading the application." Policy
should read over MEANING, not over tool names nobody can enumerate.

- Fixed category vocabulary, closed set, one word each:
  - `read`    — observes; repeatable with no cost or trace
  - `write`   — mutates state the user owns and can revert
  - `send`    — leaves the machine toward other people; hard to revert
  - `destroy` — deletes or overwrites; hard or impossible to revert
  - `spend`   — moves money or paid quota
  - `admin`   — changes permissions, keys, or membership
- `(tool-category "mcp__gmail__create_draft")` returns one symbol.
- Classification runs ONCE per unseen tool, at first mount: a single cheap
  LLM call (the resident) with the tool name, description, and input
  schema, answering with one word from the vocabulary. Batch all unseen
  tools of a server into one call.
- Verdicts persist in `~/.aimax/tool-categories.etf` (survives reload,
  survives reset — it is editor state, not chat state). The registry keeps
  `(name category source)` where source is `llm` or `manual`.
- `M-x tool-categories` opens a list-mode buffer: every known tool, its
  category, its source. `RET` on a row cycles the category and sets
  source `manual`. Manual always wins; the classifier never overwrites a
  manual verdict.
- Misclassification is safe by construction: the classifier can only make
  a tool MORE restricted than `read` in effect, because postures (C3)
  default unknown/unclassified tools to `confirm`.

### C3. Postures — category policy per chat

```scheme
'(posture (read allow) (write allow) (send confirm)
          (spend confirm) (destroy deny) (admin deny))
```

- A posture maps each category to `allow` | `confirm` | `deny`.
- `deny` applies at mount: the tool is filtered out with the bundle
  filters. Absence, not refusal.
- `allow` mounts the tool with no ceremony.
- `confirm` mounts the tool and gates each CALL on the existing
  permission flow (`chat-permission-mode` machinery). This is the one
  place a prompt survives, reserved for `send`/`spend`/`destroy`-class
  actions the user chose to keep reachable.
- The chat's posture lives in a new identity local `chat-posture`
  (add to `chat-identity-locals`, same commit). Default posture is a
  defcustom, `control-default-posture`.
- **The one Elixir primitive (only if needed):** the api lane dispatches
  bridged tools in Elixir without touching Scheme. If no seam exists
  there today, add ONE callback — before dispatch, ask the session
  `(tool-call-allowed? buf tool)`; on `confirm` verdicts route through
  the same approval path ACP uses. Verify first whether the existing
  permission flow already covers the api lane; if it does, C3 is pure
  Scheme.

### C4. Presets v2 and combos

A preset becomes a chat configuration, not a server list:

```scheme
(define-preset! 'screener
  "Reads candidates, drafts replies, sends nothing."
  '(bundles (recruiting)
    model "claude-sonnet-5"
    prompt-fragment "You screen candidates. Draft; never send."
    posture ((send deny) (destroy deny))))

(define-combo! 'hiring-day '(screener scheduler))
```

- Preset fields, all optional: `bundles`, `servers` (compat), `model`,
  `connector`, `prompt-fragment`, `posture`, `theme`.
- Merge rule for combos and multi-preset chats, in list order, later
  wins field-by-field — EXCEPT postures, which merge by MOST restrictive
  verdict per category (`deny` > `confirm` > `allow`). A combo can widen
  the tool surface; it can never widen a posture.
- `chat-presets` stays the single identity local; a combo expands to its
  preset list at load time, so restore needs no new state.
- `#+chat:` header syntax (editor.scm) gains nothing new: `presets`
  already round-trips; combos expand before writing.

### C5. Groups and grants — principals appear

Principals today are not people. They are execution contexts:

- every chat buffer
- every sub-agent / worktree thread (attribution work already names them)
- every served app buffer (`app_server.ex`)
- later: humans, in hosted/multiplayer

```scheme
(define-control-group! 'trusted   "My own hands."      )
(define-control-group! 'workers   "Sub-agent threads." )
(define-control-group! 'exposed   "Served apps; injection surface.")

(grant! 'trusted 'bundle 'recruiting)
(grant! 'workers 'preset 'screener)     ; workers get a preset, whole
(grant! 'exposed 'bundle 'nothing)      ; served apps reach no tools
```

- `(principal-group buf)` decides membership by rule, not by roster:
  chats the user drives → `trusted`; spawned threads → `workers`; app
  buffers → `exposed`. A defcustom hook lets init.scm override.
- Enforcement is again at mount: `chat-extra-tool-specs` and the ACP
  builder intersect the chat's presets with the grants of its group. No
  grant, no mount.
- The sphere is the implicit outermost group: a daemon only registers
  the servers its `VAAC_HOME` config declares, and only holds its own
  key chain. Groups subdivide inside one sphere; spheres separate trust
  domains between daemons. Do not use groups where a sphere is the
  right tool (untrusted humans get a sphere, not a group).

### C6. Surfaces

- `chat-tool-surface` (exists) grows columns: tool, server, bundle,
  category, verdict (allow/confirm/deny), and why (which preset, which
  grant). One buffer answers "what can this chat do and who said so".
- `M-x tool-categories` (C2) for the category registry.
- `M-x control-audit`: every principal → group → grants → mounted
  surface, as a foldable list-mode buffer. This is the self-evidence
  rule applied to permissions: the system can show its whole control
  state on one screen.

### C7. Persistence and the three lists

- New identity local: `chat-posture` → `chat-identity-locals`.
- No new conversation or runtime locals.
- Registries (`*bundles*`, `*control-groups*`, grants, categories) are
  editor state: definitions live in packages/init.scm and re-register on
  boot; only category verdicts persist to disk
  (`~/.aimax/tool-categories.etf`), because they are learned, not
  declared.

### C8. Tests

Through `KeyDispatch.handle_key/1` and the socket, per house rule:

- bundle filter: a denied tool absent from `chat-extra-tool-specs` AND
  from the ACP `mcpServers` payload (FakeTransport).
- posture merge: combo of `((send allow))` and `((send deny))` yields
  deny; widen-surface/narrow-posture invariant.
- categories: stub the classifier via an app-env seam (same pattern as
  `:llm_request_fun`); unknown tool defaults to `confirm`; manual verdict
  survives daemon restart; classifier never overwrites manual.
- groups: an `exposed` app buffer mounts nothing even when its buffer
  names a preset.
- restore: a chat with posture + combo survives daemon restart with the
  same mounted surface (everything survives a reload, including this).

## Order of work

C1 → C2 → C3 → C4 → C5 → C6, with C7/C8 folded into each commit. C1 and
C2 are independent and can land in parallel sessions. C5 waits for C1
(grants reference bundles). Nothing is started.
