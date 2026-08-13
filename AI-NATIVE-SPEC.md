# AI-NATIVE — the refactor, then the code browser

Written 2026-08-12 from five parallel audits: duplication, reload purity,
agent economics, apropos discovery, and a read of `~/src/codescope`.
This file is the record of what the audits found and the plan that answers it.
Read `CLAUDE.md` and `ARCHITECTURE.md` first. The one rule stands:
**Elixir supplies mechanism. Scheme decides policy.**

The goal: an AI-native Emacs with high graphical rendering and modern
concurrency. The frontend is a pure function of daemon state. Agents on both
lanes (ACP and API) share one integration with correct economics. An agent can
discover the whole API in one round-trip. Part 2 is the refactor that makes
this true. Part 3 is the code browser we build on top of it. The code browser
has its own execution plan as a Linear epic (project "Code browser").

---

## Part 1 — What the scan found

### 1.1 Money: the API lane defeats its own prompt cache

The conversation of record is a rendering artifact. `'chat-turns` stores only
prose. The wire request is rebuilt from it every turn. The rebuild never
matches the previous request, so the Anthropic cache never hits — and
`anthropic_cache_messages: true` pays the 1.25× cache-write surcharge on the
whole transcript every turn.

| id | finding | where |
|----|---------|-------|
| A1 | `tool_use`/`tool_result` blocks are absent from the replayed history; the prefix diverges at the first assistant turn | `req_llm.ex:213`, `agent.scm:256,264-269,358-361` |
| A2 | a tool-only turn records nothing; the model re-does the work next turn | `agent.scm:358-361` |
| A3 | replayed user turns lack the context preamble that was actually sent | `agent.scm:714-717` vs `:256` |
| A4 | with tools off, live buffer text sits in the *system* prompt; one edit invalidates everything | `editor.scm:1525,1549,2025-2028` |
| A5 | cache options are gated to `provider == "anthropic"`; `openrouter:anthropic/*` gets none | `llm.ex:322` |
| A6 | tool list is rebuilt per send from mutable sources; a mid-chat MCP handshake nukes the prefix | `editor.scm:2029-2031`, `mcp.scm:67-73` |
| A7 | no cache TTL option, no compaction, no window; cost grows quadratically | `llm.ex:311-335`, `req_llm.ex:213` |
| A8 | `max_tokens: 4096` hardcoded; a length stop is reported as `end_turn` | `llm.ex:312,408` |
| A9 | usage is dropped on error, round-cap, and cancel paths | `llm.ex:98-100,137-139`, `req_llm.ex:89-94,176-179` |
| A10 | cache tokens are stored but never summed or shown anywhere | `llmdb.ex:101-115`, `editor.scm:2296-2306`, `agent.scm:1074-1078` |
| A11 | cost can be priced against the wrong model; ledger rows carry no chat attribution | `req_llm.ex:162`, `llm.ex:94-96`, `llmdb.ex:70-80` |
| A12 | ACP restart pastes the whole transcript into one user message; `:resume` capability exists but nothing implements or checks it | `agent.scm:718-728`, `backend.ex:28` |
| A13 | every streamed delta rebuilds and re-diffs every block, with a full Earmark parse per prose block | `editor_live.ex:245-251,718-727` |
| B3 | no retry for 500/529 `overloaded_error`; the user resends the whole uncached transcript | req_llm retry step |

### 1.2 The reload rule does not hold

"Everything survives a reload" fails on the two most common paths.

| id | finding | where |
|----|---------|-------|
| S1 | client-scrolled buffers (≤3000 lines — nearly all) have no mount-time scroll restore; every refresh lands at line 1 | `editor_live.ex:263,279`, `layouts.ex:675-683` |
| S2 | file-backed buffers restore locals *after* the mode setup ran; the setup rebuilds from an empty map and never re-runs. Runtime locals leak back onto file-backed `.chat` buffers | `desktop.ex:252-265` vs `:236-240` |
| S3 | org fold state restores as a local but the setup never calls `org-apply-folds!` | `org.scm:610-619` |
| S4 | agent-buffer folds/overlays are computed, shipped, and discarded; `TAB` fold is a no-op in the rich view; `visible_geometry` scans the whole transcript per render for nothing | `editor_live.ex:245-256`, `editor.ex:1299-1302`, `agent.scm:92-131` |
| S5 | one `localStorage` key = one frame per browser profile; two tabs fight over `win_rows`, last writer wins | `layouts.ex:517-519,700`, `editor.ex:477-490` |
| S6 | `<details>` open state has no daemon representation; the server collapses cards the user expanded | `editor_live.ex:497-499` |
| S7 | transcript scroll stick-flag is JS-only; refresh snaps a reader to the bottom | `layouts.ex:465-477` |
| S8 | `"Shell"` and `"Chats"` name no registered mode; those buffers restore inert (no keys, no read-only) | `editor.scm:1302`, `agent.scm:1381-1394` |
| S9 | window `top` is saved but `manual` is not; the first render overwrites the restored scroll. `user_acted` clears manual on every key for all windows | `desktop.ex:129-130`, `editor.ex:591-594,1188-1196` |
| S10 | `recenter`, `scroll-other-window`, and the modeline `NN%` are meaningless for client-scrolled buffers | `editor.ex:606-618`, `editor_live.ex:844-849` |
| S11 | `render-mode` is in none of the three chat-local lists; the mode setup forces it back to "agent" on every restore | `editor.scm:1451,1728,1753-1769` |
| S12 | payload omits `read_only`, kill ring, buffer `path`, `leaf.manual` | `editor.ex:1338-1382` |
| S13 | the frame id rides a `push_event` + `localStorage` while the same id sits unused in the payload; clipboard is the only other imperative push | `editor_live.ex:36,150-156` |
| S14 | the disconnected mount renders the last-active frame — someone else's windows | `editor_live.ex:20-26`, `editor.ex:1013` |
| S15 | `subscribed` and `line_cache` assigns only grow | `editor_live.ex:202-215` |
| S16 | smaller: mail-compose overlays, collect-mode globals, which-key keymap_key mismatch, derived listings not `'transient`, `do_save` runs a full mutating render_walk every 1.5s | see audit |

### 1.3 Duplication: 33 clusters

The worst, in order. Full details live in the per-item refactor entries.

1. The chat block-model exists twice: `chat-*` (`editor.scm:1908-1969`) and
   `agent-*` (`agent.scm:23-215`). Eight function pairs over the same
   buffer-locals. `chat-abort` calls both `clear-waiting!`s because it cannot
   know which laid the marker.
2. "Where does the input region start" is computed five ways
   (`editor.scm:1931`, `agent.scm:46`, `agent.scm:806-820`,
   `editor_live.ex:767`, `editor.ex:1361`); only one handles
   `'agent-marker-bytes` and the queued prefix.
3. Five hand-rolled tabulated-list modes: dired, ibuffer, *chats*, mcp-hub,
   notmuch. Each re-implements marks, filters, refresh, current-line entry,
   and n/p remap. "Entry on current line" is pasted six times with three
   header-offset conventions.
4. Three minibuffer key tables in two languages (`editor.scm:63-76`,
   `chrome.scm:290-306`, `key_dispatch.ex:49-93`); a rebind is honored in one
   of three places. The completion-popup table in Elixir is a policy violation.
5. The browser chord path (`session.ex:400`) spawns a Task around
   `KeyDispatch.handle_key/1` and skips Input's serialization — the exact case
   with two concurrent clients. (`input.ex:29` vs `key_dispatch.ex:24`.)
6. `switch-to-buffer` defined twice; the chrome.scm redefinition wins and its
   candidate policy now differs from `kill-buffer`'s (`editor.scm:945`,
   `chrome.scm:231`).
7. Markdown→HTML twice with two stylesheets (`editor_live.ex:718-727` vs
   `:815-840`); only one wraps tables.
8. utf8-floor ×4, scheme-plist→JSON ×4, `plist-get` ×4, window-scan ×5,
   file-name prompt ×4, isearch ×2, fold registries ×2 (they clobber each
   other), model catalogs ×2, permission bookkeeping ×2, event/card
   formatting per backend, `minibuffer_key`/`buffer_key` ladder ×2,
   `ml_info`/`agent_cmd` handlers ×2, copy-policy-in-Elixir vs
   paste-policy-in-Scheme, five theme palettes restating one chrome block,
   `snapshot` vs `render_state`.
9. Dead code beside its replacement: `chat-transcript`, `chat-input`,
   `chat-clear-input!`, `chat-show-waiting!`, `chat-ready-message`,
   `chat-companion-show!`, first `yank` (`editor.scm:51`), `agent-mode` shim,
   `aimax-home` registered twice.

### 1.4 Permissions: one policy, three gates

| id | finding | where |
|----|---------|-------|
| B1 | ACP permission events carry no `raw`; deny patterns never see tool arguments on that lane | `acp.ex:310-316` vs `req_llm.ex:279` |
| B2 | `mcp-proxy-call` applies only `permission-denied-verb?`, skips the policy and the ask path, and runs the tool inside Session | `tools.scm:255-267`, vs rule at `mcp.ex:15-19` |
| C2 | rpc-id/pending/CAS permission bookkeeping duplicated in full between `agent.ex` and `req_llm.ex` | `req_llm.ex:103-146`, `agent.ex:179-197,253-297` |
| B6 | `mcp-system-note` advertises servers the chat's tool gate does not hold | `mcp.scm:262-279` vs `:67-73` |

### 1.5 apropos: not exemplary

- 128 registered docs vs ~260 undocumented Elixir primitives. Registration is
  `"name" => fn` — no doc, no arity, no category (`scheme_api.ex`,
  `session.ex`, `builtins.ex`).
- `apropos-api` matches names only, never doc text (`tools.scm:214-217`).
  `customize-apropos` and `mcp-find` in the same repo both do better.
- `apropos-api` is a tool, not a Scheme function; the raw socket cannot call it.
- 249 command docstrings + keybindings exist (M-x shows them) but no search
  reaches them.
- The raw socket has no hello: connect cold, learn nothing
  (`rpc/server.ex:81-98`). Raw-socket errors skip the did-you-mean layer.
- ACP agents get only `mcp-system-note`; the real primer `*llm-system*`
  (`tools.scm:36-76`) is reachable only on the direct chat lane.
- dired.scm, org.scm, writing.scm register zero public entries.
- No examples, no task-level recipes, no structured signatures.

---

## Part 2 — Refactor work items

Order: R1 → R2 are one arc (do together). R3 next (reload). R4–R6 next
(unification). R7 (apropos) any time after R1. R8–R9 are independent
housekeeping. Every item ends with: `mix test` green, browser verify,
screenshot, commit.

### R1 — One conversation of record

*Done 2026-08-13 on `refactor/r1-conversation-of-record`.* Two corrections
to the plan, both because the code moved: (1) the local is the ONLY stored
turn list — `chat-turns` became a derived accessor over it, so the display
surfaces (`.chat`, the seed transcript, input history) keep working with
one truth behind them, and a legacy `'chat-turns` migrates on mode setup;
(2) the record cannot be written from the event stream on the api lane —
event batches race the next turn's context read, which is what the dedup
hack was papering over. The turn task writes it synchronously instead
(`agent-record-fn!`), reading and writing in one order. ACP has no wire to
write, so it still records from events; a runtime local, `chat-wire-record`,
says which lane a chat is on. R6 should read that from the backend's
declared capabilities and delete the `connector-api?` test. The `.chat` v2
section is one JSON line below an unchanged v1 transcript, so v2 files
still read as v1. New `json-encode` primitive (the printer's escapes do not
round-trip `\r`). Tests: `test/aimax/chat_record_test.exs`.

**Why.** A1/A2/A3 share one root: `'chat-turns` is display text, but the wire
needs blocks. B5 (dedup drops a real turn) and C8 (persistence cannot
represent tool calls) are the same defect.

**What.** Introduce a structured turn list as the single source of truth.
A turn is a plist: `(role "user"|"assistant" blocks BLOCKS wire WIRE)` where
BLOCKS is a list of `(text ...)`, `(tool-use id name input)`,
`(tool-result id output is-error)` entries and WIRE is the exact user text
sent (preamble + input) when it differs from the display text.

- Store it in a new conversation local `chat-wire-turns` in
  `chat-conversation-locals` (`editor.scm:1758`), same commit.
- The API lane builds requests from `chat-wire-turns` verbatim — no
  reconstruction (`req_llm.ex:213` reads it through the context fn).
- Record assistant turns even when they contain no prose (A2).
- Record the wire user text, not the display text (A3).
- `chat-flatten` stays for display/save; delete `chat-transcript` (dead).
- Extend `.chat` save/parse (`editor.scm:1690-1735`) with a v2 section that
  round-trips blocks; keep reading v1.
- Delete the `chat-thread-context` dedup hack (`editor.scm:2018-2022`) — with
  a true record there is no double-send to dedup.

**Done when.** A tool-using chat's second turn sends byte-identical history
prefix (assert in a test by capturing two consecutive request bodies from the
context fn); a tool-only turn appears in the record; kill + reopen a `.chat`
replays tool blocks.

### R2 — Cache economics

*Done 2026-08-13 on `refactor/r2-cache-economics`, except the empirical
acceptance.* All of A4–A11 and B3 landed. Notes: the retry belongs on
`default_request` as well as `default_chat`, and req_llm reports a status
as an integer on one error struct and a string on another, nested — the
predicate walks the chain. The compaction knobs are defcustoms in
`tools.scm`, not `editor.scm`: `defcustom` is userland and loads after the
editor. Compaction runs on `turn-end` and only between turns, because the
head it replaces is the head a running request already sent; the summary
call is async, so the head is identified by count and replaced only if the
record still ends with it. **Open:** the empirical check — a three-turn
tool chat showing `cache_read > 0` on turns 2–3 — needs a real key and was
not run; everything structural around it is tested
(`test/aimax/cache_economics_test.exs`).

**Why.** A4–A11, B3. The current config pays a surcharge for nothing.

**What.**
- Stable prefix: move volatile document text out of the system prompt.
  System = static primer + tool contract. Live doc content goes into the
  *last* user message as a context block (`editor.scm:1504-1552`, `:2025-2028`).
  One `*chat-edit-protocol*` string replaces the three drifted copies
  (dup #28).
- Freeze the tool list per conversation: snapshot `(llm-tool-specs)` ++
  `(chat-extra-specs)` into a conversation local on first send. A mid-chat
  MCP handshake does not change a running chat. A `chat-refresh-tools`
  command adopts the live set (one deliberate cache miss); the modeline
  shows a hint when the frozen set drifts from the live set (A6).
- Cache controls: keep breakpoints, add `anthropic_prompt_cache_ttl: "1h"`
  as a defcustom; extend the gate to OpenRouter-routed Anthropic models
  (`llm.ex:322`) (A5, A7).
- `max_tokens` per model from the model catalog; report a real `stop_reason`
  and render a visible "truncated" note (A8; `llm.ex:312,408`).
- Retry 500/529 with jittered backoff at the `llm.ex` level, max 3 (B3).
- Usage on every path: error, cap, cancel all emit accumulated `usage`
  before the terminal event (A9). Ledger rows gain a `slug` field
  (`llmdb.ex:70-80`) (A11). Price with the model captured at turn start
  (`req_llm.ex:78,162`).
- Surface it: `chat-cost` and `LLMDb.report` show cache read/write columns
  and a hit-rate; the modeline dollar total stays (A10).
- Context management: token-estimate the record; above a defcustom threshold,
  summarize the head into one block (an `llm` call), keep the tail verbatim
  (A7). Never silent: the transcript shows a "compacted N turns" block where
  the head was. This is Scheme policy over the R1 record.

**Done when.** A three-turn tool chat shows `cache_read > 0` on turns 2–3 in
`chat-cost`; a forced 529 (stub) retries; a cancelled turn writes a ledger row.

### R3 — The frontend is a function of daemon state

**Why.** S1–S16. The invariant is stated; make it true.

**What.**
- **Restore order** (S2): `Desktop.restore_locals/2` writes locals first,
  then re-runs `set-mode!` unconditionally, matching `restore_scratch`. Fold
  both paths into one `apply_saved_state(name, point, locals)`
  (`desktop.ex:222-265`, dup #27). Use `Session.call_fn`, not string
  interpolation.
- **Scroll** (S1, S9, S10): the payload carries `top`, `manual`, and
  `client_scroll?` per leaf; the client applies `top` in `mounted()` and
  whenever `manual` is true; desktop saves `manual`. `user_acted` clears
  `manual` only on the window that received the key. `recenter` and `pct`
  compute from the same fields on both paths.
- **Frames** (S5, S13, S14): one frame per **browser window** (decided
  2026-08-12). The Chrome extension knows the window: it stamps the chrome
  window id and the page keys its frame by it, so two tabs in one window
  attach the same frame and two windows get two frames. Without the
  extension, fall back to `sessionStorage` (one frame per tab). One-shot
  migration read of the old `localStorage` key. Delete the
  `push_event("frame", ...)`; the client reads `state.frame` from the payload.
  The disconnected mount renders a neutral splash, not another frame.
- **Rich-view state** (S4, S6, S7): `ag_blocks` entries gain an `open` field
  backed by a chat local (`agent-open-cards`, conversation list); `<details>`
  becomes controlled (`phx-click` toggles the local). The transcript stick
  flag becomes a runtime local mirrored into the payload. `TAB` fold maps to
  the same `open` field. Stop calling `visible_geometry` for agent-rendered
  buffers.
- **Modes** (S8): `define-mode "Shell"` and `"Chats"`; move the chat-list keys
  and read-only into the mode setup. Rule: `buffer-set-local! 'mode-name X`
  without `define-mode X` is a bug; add a startup assertion that scans
  mode-name writers.
- **Lists** (S11): `render-mode` joins `chat-identity-locals`; the mode setup
  defaults it only when unset. `modeline-info`, `minor-modes` likewise
  classified.
- **Payload** (S12): add `read_only`, `path`, `manual`; `"copy"` becomes a
  Scheme `(clipboard-copy)` over `region-text`/`kill-top` (dup #26) and the
  clipboard push carries its result.
- **Hygiene** (S15, S16): unsubscribe buffers that leave the window set;
  prune `line_cache` on window close; mark derived listings (`*shell*`
  excepted) `'transient`; `do_save` serializes from state without the
  mutating `render_state` walk; fix `which_key` `keymap_key` lookup.
- **Streaming render cost** (A13): key the agent block cache per block
  (`{buffer, block-index, hash}`), not per buffer version; `agents-refresh!`
  updates only changed rows.

**Done when.** Restart the daemon with: a scrolled file buffer, an org file
with folds, a `.chat` with expanded tool cards, a shell, the chat list, two
browser tabs. Everything comes back where it was; the two tabs hold two
frames. Add `test/aimax/desktop_restore_test.exs` covering each.

### R4 — One chat surface implementation

*Done 2026-08-13 on `refactor/r4-one-chat-surface`.* The `agent-mode` shim
is gone with the rest: pre-unification desktops are not a case we carry
(decided 2026-08-13). `nth` was not duplicated; it moved to `editor.scm` beside
`plist-get`, since this dialect has no `list-ref`. The one genuine
duplicate registration was `aimax-home`, twice in the same `scheme_api.ex`
map. `chat-clear-input!` comes off the delete list: it is a two-line
helper over the one `chat-input-region`, so it is part of the unification,
not a casualty of it. The `models` key of a connector now accepts a thunk, which is how the
api lane declares `*llm-models*` without `connector-models` special-casing
it — that also removes one `connector-api?` call site ahead of R6.

**Why.** Dup #1, #2, #3, #15, #18, #19, #20, #29, #32.

**What.** Keep the buf-keyed set; delete the `agent-*` wrappers.
- One `*chat-input-marker*`; one `(chat-input-region buf) -> (start end)`
  used by Scheme readers and shipped in the payload for `ag_input`.
- One `(chat-surface-init! buf title lines)`; `group-chat-show!` becomes the
  only layout builder and `chat-adopt` calls it.
- One fleet scan: `chat-list-bufs` + `chat-row-status`; `agent-threads`
  becomes a filter over it.
- One model catalog keyed by connector; the api lane is a connector like the
  others (`editor.scm:2049`, `agent.scm:1088-1105`).
- Delete: `chat-transcript`, `chat-input`,
  `chat-show-waiting!`, `chat-ready-message`, `chat-companion-show!`,
  `agent-toggle-view` (bind `chat-toggle-view` everywhere), first `yank`,
  `agent-mode` shim, `nth`, `chat-history-take`, duplicate `aimax-home`
  registration.
- `agent-revive!` and `chat-ensure-runtime!` merge into one attach fn;
  `chat-switch!` calls `agent-reconnect!` instead of reimplementing it.

### R5 — One permission gate

*Done 2026-08-13 on `refactor/r5-one-permission-gate`, except one half of
B2.* The thread owns the pending slot for both lanes: `Agent.ask_permission/2`
blocks the direct lane's turn task on the same slot an adapter's own
request occupies, so one rpc id, one CAS, one deadline, one deny-on-close.
The verdict now reads the option's **kind**, not its id — an adapter names
its own ids. ACP supplies `raw` from the whole tool call, so the deny
patterns finally see arguments on that lane. The gate fails closed on a
policy crash and says which policy to fix.
**Open:** `mcp-proxy-call` routes through the one policy now (that was the
real defect — it applied the deny-list alone, so a chat in `ask` mode was
in ask mode everywhere except there), but it still dispatches in the
session. It cannot do otherwise: the surface it serves is the Scheme tool
registry, and a Scheme handler runs in the session by definition. The
"never dispatch in the session" rule in `mcp.ex` is about MCP tools, which
this surface does not expose. Getting a proxy call off the session needs a
deferred-reply RPC design — worth its own item if it matters. A proxy call
has no chat to raise a banner in, so `ask` is a refusal there.
A second open edge (found 2026-08-13): the fail-closed crash guard sits on
the Elixir gate only. The ACP lane (`agent.scm:342`) and the proxy
(`tools.scm`) call `*permission-policy*` from Scheme with no guard of
their own; a policy crash there fails the eval instead of denying cleanly.

**Why.** B1, B2, B7, C2, C3. Three chokepoints, three policies.

**What.** The gate lives in `agent.ex`: rpc-id allocation, pending slot,
CAS, deny-on-close, option-kind vocabulary. Backends supply
`{title, kind, raw}` and receive a verdict.
- ACP includes `raw` built from the tool call payload (`acp.ex:310-316`).
- `mcp-proxy-call` routes through the same gate with the chat's slug and runs
  the tool in a Task, not in Session (`tools.scm:255-267`).
- `mcp-system-note` lists only the servers the chat's presets actually expose
  (B6).
- Fail closed on policy crash: deny the call, raise a needs-attention banner,
  log the crash. A buggy policy stalls agents until fixed; that is the
  intended trade (B7 — decided 2026-08-12, reverses the current fail-open).

### R6 — Backend seam honesty

*Partly done 2026-08-13 on `refactor/r6-backend-seam`.* Landed: the thread
assembles a turn's context and hands it through `Backend.prompt/3`; the
backend no longer reads the ETS closure (the entry stays — it is what
roots a closure that escapes into long-lived processes; ONE caller looks
it up now). The fetch runs in a task and must, or the session waits on the
thread while the thread waits on the session — so the context comes back
stamped with its turn, and a cancel racing a fetch can no longer start a
turn for a message the user took back (C9's guard, plus a `:busy` reply on
a second prompt). `Aimax.Scheme.Text` replaces the four UTF-8 boundary
copies (dup #10).
C6: `Backend.error_text/1` turns a crash reason into a sentence; an
unrecognized reason falls back to a bounded `inspect` (limit 5, 200
printable bytes) — a short raw term can still reach a transcript. C7: backends declare `:stateless` and
`:metered`, Scheme asks `connector-can?`, and every "is this the api
lane?" test is gone — including the `chat-wire-record` local R1 left
behind, which is deleted. A12: `:resume` is REMOVED rather than
implemented. ACP defines `session/load`, but resuming needs a session id
that outlives the daemon and nothing persists one; declaring a capability
no backend can honour is worse than not having it. The seed path stays and
now says so in the transcript — a pasted conversation must not pass for a
continued one.
Presentation is out: the backend sends `name` + `input` + `output` raw,
and `agent-tool-title` / `agent-tool-input-text` / `agent-tool-update-text`
in `agent.scm` decide what a card says, with two defcustoms for the
limits. An adapter that has only a title still keeps its title, so the ACP
lane is unchanged. **R6 is done.**
**Suite health:** seed 0 is green, but roughly one full run in three shows
a single failure somewhere in the shared-Editor tests (notmuch, chrome —
`:noproc` on a buffer another test killed, window state). The parent
commit does the same at the same rate. Given what the `C-c q` bug turned
out to be, some of these are probably latent test bugs that timing shifts
expose. Worth a sweep of its own.
*The `C-c q` flake was a test bug, not a regression.* The fixture buffer is
named `test-<counter>`, the counter often contains `42`, and the stub's
reply was the string `"42"` — so `eventually(text =~ "42")` matched the
buffer's own name in the help card and returned before the turn had
rendered anything. The next assertion then raced the event batch. Moving
the context fetch into a task made the batch land late enough to expose
it. The stub now replies with words, and both assertions wait. 100 repeats
clean. Worth remembering: an `eventually` that can match chrome is not a
wait at all.

**Why.** C1, C4, C6, C7; A12.

**What.**
- `Backend.prompt/3` receives the context it documents: `%{turns, system,
  tools, display}` built by `agent.ex` from the R1 record. Delete the
  `{:agent_context}` ETS global (`req_llm.ex:358-378`).
- Presentation moves out of `req_llm.ex`: tool-card title/summary/truncation
  become Scheme/`editor_live` concerns fed by raw events; one
  `Text.floor_utf8/2` + `ceil_utf8/2` replaces the four copies (dup #10).
- One error model: both lanes emit `error` + `turn-failed` with a clean
  message; no `inspect/1` leaks into transcripts (C6).
- Capabilities read from `capabilities()` in Scheme; delete
  `connector-api?` special-casing (C7). Implement or remove `:resume` —
  implement for ACP `session/load` where the adapter supports it, else keep
  the seed path but mark it in the transcript (A12).
- Guard `state.task` overwrite (C9).

### R7 — apropos: exemplary discovery

*Done 2026-08-13 on `refactor/r7-apropos`, minus the primitive doc sweep.*
One correction, and it reverses a decision in this file: **there is no
`apropos-ask`.** I built it and deleted it. The caller of that tool is
already a model, with the primer in its context; `(apropos "words")`
answers deterministically, recipes hand back the whole composition, and a
wrong name comes back with the nearest real ones and their signatures. A
second model call — with the whole catalog re-inlined — buys nothing the
first call lacks, and adds cost, latency, and a hallucination that has to
be checked with `boundp` before it can be trusted. The catalog belongs in
the caller's context, which is where it already is.

`public!` parses the signature out of the doc (the house convention had
written one for 95 of 126 entries with nothing reading it) and carries a
category, set once per section with `(category! 'name)`. `(apropos ...)`
searches recipes first, then the public API, the M-x commands and their
docstrings, the keybindings, and the defcustoms — word-AND, with an
edit-distance fallback. `recipes.scm` holds ~30 task→expression lines. The
RPC server answers `initialize` with `(hello)`, and raw-socket eval errors
run the same did-you-mean the tool path gets. An ACP agent gets the primer
on `session/new`.
*The doc sweep landed 2026-08-13 (post-merge, on `main`).* Three `docs/0`
maps beside the three registration maps (75 + 124 + 77 entries), served
by `(primitive-doc NAME)` and `(primitive-docs)`. `describe-function`
shows the doc above a builtin's source marker; scope "all" returns
internals as `(kind name doc)` entries and matches on doc text. One
find during the sweep: five "undocumented" names were userland aliases
of builtins — the lookup now resolves through the value to the real
name. Four tests hold coverage and format. **R7 is done.**

**Why.** Part 1.5. The agent's first question is "what can I call"; today
the honest answer is "read the source".

**What.**
- **Metadata at registration.** Elixir primitives register as
  `{name, fn, doc, sig, category}` via a `defprim` helper; `public!` grows
  optional `sig`, `returns`, `category`, `example` fields (back-compatible:
  two-arg form still works). Every primitive in `scheme_api.ex`,
  `session.ex`, `builtins.ex` gets a one-line doc and sig. dired/org/writing
  register their public surface.
- **One search.** `(apropos QUERY)` — a real Scheme function *and* a tool —
  searches name + doc + category + command docstrings + keybindings +
  defcustoms + MCP tool descriptions. Word-AND matching like `mcp-find`,
  edit-distance fallback from `tool--suggest`. Returns structured plists with
  sig and doc. `(apropos-category NAME)` lists a category.
- **Recipes.** A curated `recipes.scm`: task → expression, e.g.
  `"open a file in a split" → (begin (split-window! 'h) (visit PATH))`.
  `(apropos ...)` searches recipe titles first. Start with the 30 tasks agents
  actually perform (window ops, buffer edits, dired, chat control, tabs).
- **Socket bootstrap.** The RPC server answers `initialize` (and a bare
  `(hello)` eval) with: the primer (one merged text replacing `*llm-system*`
  + `mcp-system-note` + the preamble copies, dup #28), the category list, and
  the three canonical search calls. Raw-socket eval errors run the
  did-you-mean layer (`server.ex:88-91` wraps eval like the tool path does).
- **ACP parity.** The MCP proxy exposes `apropos` as a tool and the primer
  rides `session/new` system text.
- **LLM assist, no RAG.** ~~Add `(apropos-ask QUESTION)`~~ — REVERSED, see
  the status note above. The caller is already a model with the primer in
  its context; a second model call buys nothing `(apropos ...)` lacks.

**Done when.** A cold agent on the socket resolves "split the window and open
file X in it" to the right expression in one `initialize` + one `(apropos ...)`
round-trip. Add a test that walks `(public-api)` and asserts every entry has
sig + category, and one that asserts every registered primitive carries a doc.

### R8 — `define-list-mode!`

*Partly done 2026-08-13 on `refactor/r8-list-mode`.* `define-list-mode!`
owns marks, the filter stack and its label, the point-preserving refresh,
`(list-current)`, the n/p remap, per-row overlays, and mode registration —
so S8 falls out rather than being fixed separately (`*chats*` named
"Chats", a mode that did not exist). `line-index-at` takes the header
height as an argument instead of assuming it, replacing six copies with
three different conventions. Ported: **ibuffer, `*chats*`, mcp-hub**.
**Not ported, and not mechanically portable: dired and notmuch.** dired
opens ONE BUFFER PER DIRECTORY, its rows are read back out of the line
text by column offset, and its marks live in a global alist keyed by
buffer. `define-list-mode!` assumes one fixed buffer per mode with a
stored entry list. Porting dired means generalising the abstraction to
per-buffer instances — a design change, not a port — and dired is the
most-used list in the editor. notmuch is 1122 lines with thin coverage.
Do these two together, deliberately, or leave them: three of five already
removes the duplication that was actually costing.

**Why.** Dup #4, #5. Five copies of tabulated-list.

**What.** One `define-list-mode!` in editor.scm taking `rows-fn`, `render-row`,
`keys`, `header-lines`. It owns: marks, filter stack + label, point-preserving
refresh, `(list-current)`, n/p remap, and registers a real mode (S8 falls out).
Port dired, ibuffer, *chats*, mcp-hub, notmuch one per commit. One
`(line-index-at buf header-lines)` helper kills the six copies.

### R9 — Housekeeping bundle

*Partly done 2026-08-13.* Landed across the items that carried them:
`Aimax.Scheme.Text` (dup #10, in R6), `Aimax.Core.Plist` (dup #11), one
`plist-get` (dup #12 — `custom--plist-get` keeps its name for its 27 call
sites and loses its body, which crashed on an odd-length plist),
`mcp-status` delegates to the hub (dup #31), the window helpers (dup #16 —
four functions, because five hand-rolled scans were asking four different
questions and disagreeing about what "no match" returned).
**Skipped by carve-out:**
tagged folds (SVS-193), `markdown_html/1` (SVS-198). *`read-file-name`
(#17) landed 2026-08-13 on `main`: one file prompt behind find-file,
tail-file, load-file and dired. One isearch engine (#13) landed the same
day: `isearch-loop` + `search-find`/`search-find-wrap` behind both C-s
and evil's / ? n N; each surface keeps its own hit rendering and wrap
policy.* **Not done:** the
KeyDispatch ladder merge and completion keymap (#21-23), `ml_info`/
`agent_cmd` merge (#24), raw locals in the payload (#25),
`buffer-candidates` and tabs (#6, #7), `define-theme-from` (#33),
`kill-region-1`/`llm-on-region` (#30), `advise!`.


Small, independent, one commit each:
- `Text.floor_utf8/2`/`ceil_utf8/2`; delete the other three (dup #10).
- `Aimax.Core.Plist.to_json/2`; delete acp/session copies (dup #11).
- One `plist-get` in editor.scm; delete custom/agent/chrome/notmuch copies
  (dup #12).
- Window helpers (dup #16) — landed as four: `window-showing`,
  `window-showing-other`, `window-buffer`, `other-window-id`.
- `(read-file-name prompt k)` (dup #17).
- One isearch engine, two surfaces (dup #13).
- Tagged folds: `(fold-set! buf tag ranges)` over `buffer-set-hidden!`; org
  and agent stop clobbering each other (dup #14). Org setup calls
  `org-apply-folds!` (S3).
- `resolve_and_run` merges the two KeyDispatch ladders (dup #21); the
  completion popup reads a `" *completion*"` keymap from Scheme (dup #22);
  `dispatch-keys` goes through Input (dup #23).
- Merge `ml_info`/`agent_cmd` handlers; whitelist moves to Scheme (dup #24).
- Payload ships raw locals; delete Elixir-side `group`/`companion-of`
  fallbacks (dup #25).
- `markdown_html/1` + one stylesheet for chat prose and preview (dup #9).
- `buffer-candidates` unified; chrome adds tabs instead of replacing the
  command; one tab-label format and one `chrome--goto-tab!` (dup #6, #7).
- `(define-theme-from base overrides)`; give "paper" its `ts-*` faces
  (dup #33).
- `kill-region-1`, `llm-on-region` (dup #30). `mcp-status` delegates to the
  hub (dup #31).
- One `defadvice`-style `(advise! name fn)` helper replacing the six
  hand-rolled wrap-by-redefinition sites.

### R10 — Tests that hold the line

*Done 2026-08-13, except the restore suite.* Written with each item rather
than at the end: `chat_record_test.exs` (prefix identity across two turns,
a silent tool round in the record, the `.chat` block round trip, v1 still
opening), `cache_economics_test.exs` (the system prompt holding still, the
frozen tool list, a cancelled turn billed, the hit rate, truncation, the
529 retry, catalog `max_tokens`), `permission_test.exs`'s "one gate"
(the same payload refused at all three chokepoints, ask mode holding on
the proxy, the fail-closed crash path), `apropos_test.exs` (every entry
carrying a sig and a category, doc text searched, the cold start).
Key-level tests drive `KeyDispatch.handle_key/1` throughout. **The restore
round-trip suite belongs to R3, which is blocked.**


- Cache: two-turn request-body prefix equality (R1/R2).
- Restore: the R3 round-trip suite.
- Permission parity: same deny pattern fires on both lanes and on the proxy.
- apropos: coverage assertions (R7).
- Keys through `KeyDispatch.handle_key/1` as always.

---

## Part 3 — The code browser

### The point

Watch an agent work, from inside the editor, with the editor's own verbs.
Example session: left window holds the agent thread; right window holds a
live git diff of the repo the agent edits; `RET` on a diff line jumps to the
file; the agent mentions `apps/foo/bar.ex` in prose and it is a link; an HTML
file the agent writes renders as a page and re-renders on every edit.

`~/src/codescope` is the reference. We take its ideas, not its stack.

### What we take from codescope

- **Path autolinking in prose**, verified against the filesystem so links are
  never dead (`codescope docs.ex:78-94`).
- **Structural hjkl navigation with indentation fallback** and
  current-scope highlight (`app.js:206-353`) — rebuilt on our tree-sitter
  NIF, no CLI, no Monaco.
- **Line-count-gated default folding** (small files open, big files fold to
  signatures).
- **Content-free change broadcast**: one debounced `fs-changed` event;
  subscribers re-query.
- **Sandboxed iframe preview** with a raw endpoint so relative assets work;
  a directory with `index.html` previews as a site.
- **Artifacts as files in the repo** (later: generated docs under `.aimax/`,
  the class-palette contract for LLM-written HTML).

### What we do not take

- Monaco, CDNs, client-side tokenizers. Rendering stays in the display
  payload; the client stays a pure view.
- Synchronous work in the view process. Git, parsing, and watching run in
  Tasks and GenServers; results land as buffer updates.
- A second navigation model. Everything is a buffer; URLs are buffer names.

### Design

Mechanism (Elixir), one module each, all off the Session process:
- `Aimax.Core.Git` — status/diff/log/show via `System.cmd` in `Task`,
  porcelain-z and unified-diff parsers. Parsers are mechanism.
- `Aimax.Core.Watch` — one FileSystem subscription per watched root, 150 ms
  debounce, broadcasts `{:fs_changed, root}` content-free.
- `/raw/*path` in aimax_ui — traversal-guarded byte serving with MIME, for
  iframes and images.

Policy (Scheme, `priv/packages/`):
- `git.scm` — diff-mode buffer, rendered as a rich render-mode (decided
  2026-08-12): the buffer text stays the unified diff — the byte-addressable
  source of truth, so point motion, `RET`, folds, and restore all work — and
  the payload ships a parsed block model on top: per-file cards with
  side-by-side old/new rows, intra-line word diff, controlled open state
  (the R3 pattern). `decorate/3` grows a "diff" branch beside "agent".
  `C-c C-v` toggles the plain unified view, like chat. Keys: n/p hunks,
  N/P files, `RET` → `(visit file)` + goto line, `g` refresh, `w` watch mode
  (auto-refresh on `fs-changed` and on `{:agent, id}`-provenance buffer
  changes).
- `code.scm` — code-browse minor mode: hjkl structural nav with indent
  fallback, scope highlight overlay, default fold policy, imenu jump.
- preview — file-backed HTML buffers preview via `/raw` iframe (relative
  assets work); image files open as image buffers; previews re-render on
  buffer change and `fs-changed`.
- autolink — chat prose and doc HTML get file-path links; click runs
  `(visit path)`.
- `watch-agent` — the composed layout command; one binding from the chat.

The epic (Linear project "Code browser", team Svsrecruiting) carries the
execution plan: issue-level detail, ordered, each executable by Sonnet
without this conversation.

### Tree-sitter now, LSP later

The browser's navigation is syntax-level: tree-sitter gives structure,
folding, scope, and outline per file, with zero setup and an indentation
fallback. Semantics — cross-file go-to-definition, references, hover types —
need LSP, which is already queued in `HANDOFF.html` as its own subsystem
(JSON-RPC over Port, per-language servers). The browser does not wait for
it. It leaves the seam: symbol jump routes to `(lsp-definition)` when a
server is attached and falls back to a tree-sitter same-file search when
not — the same degradation pattern as ts → indentation.

### Prerequisites from Part 2

Hard: tagged folds (R9), `markdown_html/1` (R9), payload `path` field (R3).
These are folded into the epic's issues where small. Soft: R3 scroll
ownership makes diff buffers behave under refresh; R1/R2 make the observed
agent affordable.

---

## Part 4 — Landmines (inherited, still true)

- Points are byte offsets. Marker math bites; test with multibyte text.
- A daemon restart is required for `priv/*.scm`; the browser reloads itself.
- HEEx `<style>` interpolation is disabled; use `<%= raw(...) %>`.
- Umbrella tests share one BEAM and one global Editor; assert relatively.
- Chat locals: every new chat buffer-local joins exactly one of the three
  lists in the same commit.
- The user runs concurrent sessions in this tree: `git status` before
  committing; commit only your files.
