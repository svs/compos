# Simplification audit

Seven read-only audits of the tree on 2026-09-18. Each item names the file,
states the fault, and gives the simpler shape. Line numbers are from the tree
on that day. Nothing here is started.

Companion documents: `SIMPLIFY-SPEC.md` (ONE CHAT, 2026-08-08) and
`CLEANUP-QUEUE.md` (2026-08-22). Items from those that this audit re-confirmed
are marked (CQ #n).

## 0. The numbers

| Surface | Now | Target | How |
|---|---|---|---|
| Scheme in stock boot (no tests) | 81.7k | ~40k | 7k stays in scheme/packages/, out of boot; 30k is duplicate or dead |
| editor.scm | 15.3k | ~4k | 9.5k moves to packages; 2.8k deleted; 0.8k of comments to docs |
| Elixir | 49k | ~25k | 4.7k of JS/CSS to static files; two LiveViews to one; duplicate modules |
| Tests | 78k | ~40k | 43 wrapper files, 40 double-covered features, demo-app tests |
| Docs | 66 files, 13.7k | ~27 files, ~7k | stale and superseded out; the essays stay |
| Primitives | 582 | ~350 | 52 unreferenced, 25 dual spellings, families to one door |
| Commands | 986 | ~650 | 160 window commands to 55; 90 app commands out; 60 leftovers |
| Defcustoms | 253 | ~120 | 88 have one reader in their own file; 41 belong to apps |
| Chat buffer-locals | 74 + ~20 undeclared | ~40 | runtime state lives in the Agent process |
| Frame-local keys | 48 | ~15 | one window-configuration slot map |
| Recency stores | 7 | 1 | |
| Preview mechanisms | 7 | 1 | |
| "Put the frame back" mechanisms | 12 | 1 | |
| Ways to run Scheme | 11 | 3 | lane, task, rpc |
| Persistence mechanisms per buffer | 5 | 2 | Loro log + desktop |
| Hook mechanisms | 6 | 1 | |
| Prompt doors | 5 | 1 | |
| Mode definers | 6 | 1 | |
| JSON-RPC framers | 5 | 1 | |
| Markdown renderers | 3 | 1 | |
| Model catalogs | 3 | 1 | |
| PTY runners | 1 | 1 | done (b96c18fd) |
| Observability surfaces | 6 | 2 | one event stream, one sample |

Roughly 210k lines including tests becomes roughly 105k.

## 1. The target shape

**Elixir: ten mechanisms.** Interpreter. Buffer (rope + Loro log, points,
locals, ranges). Editor (frame map, window tree ops, one render row model).
KeyDispatch (one lookup that asks Scheme). Lane (serial per key) + Task
(one-shot). Transport + JsonRpc (one framer; ACP, LSP, MCP, Codex are
vocabularies). Backend base + ReqLLM + ACP. Hotload. Desktop. Telemetry
stream. Each connector module exports its own primitives with docs in one
`prim` macro.

**Scheme kernel: ~4k lines in editor.scm.** Catalog (one table). One
`define-mode` with keyword args. `define-command`. Hooks, including keyed
hooks. Keymaps as data with the ladder in Scheme. Files and the write door.
The display-buffer chain. One `window-configuration` value. Minibuffer as a
buffer with a mode. Tabulated list with a `'surface` option.

**Packages: one per domain, no private helpers.** chat, agent connectors,
groups, layouts, dashboard, look (peek), lists, terminal, remote, isearch,
dired, notmuch, web, morg, lsp, treesit, jj, worktrees.

**User config: providers and personal apps.** A seam in core is one custom
that holds a function. The config supplies the function:

```scheme
(set-custom 'secret-provider
  (lambda (name) (shell-out "doppler" "secrets" "get" name "--plain")))
```

No registry, no wrapper package.

**Layout.** `apps/compos_core/priv/*.scm` holds the kernel only: editor.scm
and the boot files. Every package lives at the project root in
`scheme/packages/`. init.scm lists the stock packages; amazon, linkedin,
substack, spotify, movie, doom, doom-lite, spreadsheet, graphql, calendar,
px0, title, training, recording, peers are in `scheme/packages/` too, out of
init.scm, and load only when the user init names them.

The door is Emacs's: a `load-path` list, and `load` of a relative name
searches it. The kernel sets the default, so init.scm and the user init
load by bare name and add a directory only for something outside the tree.

```scheme
;; editor.scm
(defvar 'load-path
  (list (compos-priv-dir)
        (string-append (compos-project-dir) "/scheme/packages")
        (compos-home)
        (string-append (compos-home) "/packages")))

;; init.scm and ~/.compos/init.scm
(load "notmuch.scm")
```

Today `load` (session.ex:2550) takes one expanded path and searches nothing;
init.scm and package.scm hardcode `(compos-priv-dir)`; Hotload names its
roots in Elixir (hotload.ex:137-147); the Scheme write roots are a third
list (editor.scm:6371). All four become readers of `load-path`: `load`
searches it in Scheme over the one-path builtin, Hotload asks Scheme for it
at boot and on change, the write roots derive from it, and the release
copies every entry. `load-bundled-package` and its five hand-expanded
copies in init.scm go away.

## 2. What to look for (the patterns every audit found)

These are the tests to run against any file. Each one names the audits that
hit it.

1. **One fact, N stores, plus sync code.** 7 recency rings; current group in
   3 places; attribution in 3 (Loro commit, authors spans, edit_log); text in
   2 (rope + Loro) with a cross-check on every checkpoint; commands in 3
   registries; messages in ETS and a buffer; faces in 4 places.
2. **One mechanism, N names.** 7 previews (peek, listing-preview, candidate,
   collect, switch, ibuffer, group); 12 frame restores (winner, transient
   frames, popup-return x3, overview-return, group layouts, hidden windows,
   switch/ibuffer restore-home, quit-restore, layout-focus-token); 6 hook
   mechanisms; 5 prompt doors and 5 question readers; 6 mode definers; 9
   "special buffer" predicates.
3. **A special case beside a generic that covers it.** 62 curl call sites
   beside `http-request`; popup identity parsed from a CSS class string
   beside a window leaf; an "agent" render mode beside "blocks"; Google's
   private Bandit listener beside web_server.ex; two PTY runners; five
   JSON-RPC framers beside Endpoint.Conn, which already has every framing.
4. **Policy that leaked into mechanism.** The keymap ladder (360 lines of
   editor.ex); minibuffer and completion rules across 4 Elixir modules; word
   syntax and kill-line in buffer.ex; the kill fallback picked in Elixir and
   then re-picked in Scheme; prompt strings, model defaults, retry budgets
   and buffer names in agent.ex, llm.ex, and the backends; key policy in the
   JS of layouts.ex.
5. **Dependency arrows pointing the wrong way.** editor.scm calls 129
   symbols that 28 packages define, through 79 `boundp` guards. The kernel
   creates package keymaps (spotify-map, annotate-map). dired wraps all 15
   of its commands for google.scm. This is why chat, lists, dashboard and
   layouts never moved out.
6. **Migrations that run forever.** `Desktop.upgrade` and `Buffer.upgrade`
   on every message; chat-input-migrate!, chat-record-migrate!, the
   companion-of upgrade, llm-bundles-assign-keys, the llm-responses mirror;
   every buffer change broadcast twice for a "compatibility alias".
7. **Registered but never read.** 52 primitives with no production caller;
   88 defcustoms with one reader in their own file; 103 commands reachable
   only by M-x, 60 of them leftovers; 22 of 37 face aliases; 10 commands
   that exist for their test.
8. **Metadata that does not pull its weight.** 1,150 lines of catalog stamps
   across 231 files with 4 runtime readers; the apropos engine (850 Scheme +
   368 Elixir + OpenAI embeddings) to search docstrings; 248 public! entries
   that restate a signature the define already states.
9. **A builtin gap that N files patch.** `plist-get` throws on `#f`, so 25
   wrappers exist; no `string-replace`, `html-escape`, `take`, `string-clip`,
   `alist-put!`, so 40 private helpers exist; `sh-quote` is public but 8
   packages copy it.
10. **Two-way registration.** Every primitive lives in an impl map and a
    parallel docs map (900 lines); one name is registered twice with the
    later merge winning.
11. **Tests that duplicate or preserve.** 43 wrapper files around one bridge
    that already runs every Scheme test; 40 features tested in both suites;
    7 FakeTransport copies; 144 private `eval!` helpers; 61 files assert
    production chords.
12. **Comments as changelog.** 23% of editor.scm is comment, much of it
    "the bug this line prevents" and dates.
13. **Name collisions.** chrome (extension, window overlays, a face);
    transient (menu, frame); backend/connector/lane/provider for one thing;
    setup/bundle/preset/combination/history entry/workspace defaults for one
    record; shell/term/comint crossed against Emacs.

Lenses this audit did not run: usage telemetry (which commands anyone runs,
so deletion is data-driven); the 4.7k of CSS and JS in layouts.ex against
docs/COMPONENTS.md; the ~45 files Scheme and Elixir write under `~/.compos`
with no manifest; a latency benchmark for the one-serial-world execution
model (item 8.4).

## 3. Kernel: editor.scm

Verdict per section (line ranges of 2026-09-18):

| Section | Lines | Verdict |
|---|---|---|
| catalog, package stamps | 1-200 | kernel; `catalog-meta!` merge duplicates `catalog-register!` |
| define-command, interactive spec | 201-314 | kernel; string codes and 'b 'd 'm unused |
| public! registry | 315-395 | delete: second copy of the catalog |
| tabulated lists | 396-2656 | package `tabulated-list.scm` (2,261 lines, 48 callers all outside) |
| minibuffer | 2907-3472 | kernel ~300 after one door; rail to groups; shape cycling has no caller |
| hooks | 3473-3576 | kernel |
| defvar-local family | 3577-3647 | delete (0 production callers) |
| marginalia, chrome | 3648-3801 | package |
| modes | 3904-4161 | kernel ~120; icons, link syntax out |
| visual lines | 4604-4840 | package |
| isearch, hl-line, font-lock, replace | 5834-6145 | package; font-lock keywords has no setter |
| remote files | 6781-7020 | package |
| popper | 7513-7886 | package, one `popup-show!` |
| peek | 8379-8776 | package `look.scm`; peek.scm is a second peek |
| tiling, window-layout commands | 9061-9440 | layouts.scm |
| collect | 9441-9718 | package |
| terminal, comint, tail | 9719-9885 | package |
| LLM pipes, llm-mode, chat-mode, bundles, transcript | 9886-12092 | packages (2,207 lines) |
| modeline dashboard | 12209-13320 | package `dashboard.scm` (~960) |
| command palette | 13574-13736 | package |
| direction families, arrow installers | 14033-14248 | layouts.scm; 0-caller tables deleted |
| public API | 14876-15276 | shrink to ~100 |

Findings:

1. Four registrations per command (Elixir ETS, `*command-fns*`,
   `*command-names*`, catalog) and two per public function. Three copies of
   "replace, touch generation, notify apropos" at E:126, 186, 303. One
   catalog keyed "kind:name"; `public!` = `catalog-register!`.
2. Six mode definers, seven per-mode side tables (`*mode-parents*`,
   `*mode-docs*`, `*mode-icons*`, `*mode-link-syntaxes*`,
   `*dismissible-modes*`, `*mode-layouts*`, `*mode-headlines*`), nine
   hand-written minor-mode toggles, four ways to re-run setup by name, three
   ways to rebuild. One `(define-mode NAME 'parent 'minor 'keys 'doc 'icon
   'setup 'teardown)` and `(mode-get MODE KEY)` with the parent walk.
3. The alist upsert idiom appears 34 times in editor.scm and 121 in priv;
   `hook--alist-put` is that function. `alist-put!`, `alist-get`,
   `alist-delete` become builtins beside `assoc`.
4. Six hook mechanisms: add-hook!, on-X! wrappers, keyed registries
   (`*preview-link-verbs*`, `*marginalia*`, `*context-providers*`,
   `*embark-actions*`, `*paste-hooks*`), the Elixir single handler fanned
   out, re-`set!` seam lambdas (buffer-project-label, switch-buffer-source,
   display-foreign?, buffer-kill-repair, candidate-face-for), and
   frame-attached!. Keyed hooks `(add-hook! '(preview-link "def") fn)`
   replace all of them and the 79 boundp guards.
5. Five prompt doors (minibuffer-read*, minibuffer-read, completing-read,
   minibuffer-read-preview, read-string) and five question readers (read-char
   = read-char-choice; y-or-n, y-or-n-p, yes-or-no-p). The M-a..M-z shortcut
   generator registers 35 commands, 23 of which do nothing.
6. Six variable mechanisms (define, defvar, defvar-local family, defcustom,
   persist-global!, buffer-set-local!). `(defvar 'x default 'persist #t)`
   replaces persist-global! and its 15 get/put closure pairs.
7. Shadowed definitions: E:2790-2851 (preview-goto-pos! and friends) is
   overwritten by preview.scm:330-436; the editor copy lacks url-decode.
   scheme-mode, html-mode, elixir-mode, json-mode are redefined by
   treesit.scm:57-74 and file-view.scm:39. Eight layout variables are
   defined here and defcustom'd again in layouts.scm.
8. Dead: dash--seg-gap, list-filters-label, list-stamp!,
   llm-mode--stream-range!, reload-refresh-modes!, scroll-other-window-by!,
   `*minibuffer-shapes*`, list-filter-clear, list-more,
   toggle-window-animations, scroll-popup(-down), and 24 define-commands with
   no key and no caller. Test-only: buffer-unselect(-all),
   desktop-apply-mode!, display-action-for, chat-set-backend, popup-move-*,
   window-prefers-buffer?, run-hook-with-args-until-*, the magic and
   interpreter mode alists, kill-all-local-variables!.
9. Copy-pasted bodies: the save epilogue 6x (E:6446-6547); the visit body 4x
   (E:7005-7152); the remote-sh! wrapper 9x (E:6910-6983); the mb-list
   prompt door 3x (E:1945, ibuffer.scm:1761, agent-fleet.scm:1306); "another
   window that is not the popup" 7 finders with 3 exclusion sets.
10. Emacs parity nobody uses (~450 lines): mark ring + global mark ring;
    font-lock keywords; command-call/call-interactively; read-number,
    read-buffer, current-kill; define-globalized-minor-mode! (evil only).
11. Nine special-buffer predicates. `buffer-special?` = derived from
    special-mode; `chat-buffer?` = the 7-site inline guard.
12. Chat locals: three lists, 77 names, ~40 belong to packages;
    'agent-mode-wanted is in no list; llm-mode keeps an undeclared fourth
    set. `(local-class! 'name 'identity|'conversation|'runtime)` declared
    where the local is defined.
13. Reimplemented builtins: nth (unsafe list-ref) x4, list-tail-n,
    name--trim-left/right, name--index, sort-by-car, catalog--get,
    chrome--get, transient--put, abbreviate-home, move-lines.
14. One-shot migrations on every boot: shell-mode alias, companion-of
    upgrade, chat-input-migrate!, chat-record-migrate!, llm-bundles-assign-keys,
    the llm-responses mirror. One desktop migration pass with a cut-off.
15. Keys bound from six sections; C-c b bound 3x; C-c m 3x to two commands;
    the dashboard hardcodes chord names in rows.
16. Small bootstrap files: transient.scm and chrome.scm are packages;
    themes.scm restates ~60 faces per palette 4x, 15 ts-* faces have no
    producer, 22 of 37 Emacs face aliases have 0 references; three settings
    files (transient-values.scm, theme.scm, custom.scm) for one thing.
17. Blocks: four fence finders under five vocabularies; five block files
    hand-write the package prologue; init.scm hand-expands
    load-bundled-package three times.

## 4. Windows, groups, layouts, lists

Inventory: frame (Elixir map + a Scheme `*frame-locals*` shadow with 48
keys), window, popup (a window whose buffer carries a CSS class string that
Elixir parses at editor.ex:2936), display-buffer chain, target layout, peek,
listing-preview, candidate preview, collect, switch-preview, ibuffer-preview,
group-preview, detail, group (groups.scm 4,372 = five packages), current
group (3 copies), sealed groups, group MRU (7 recency stores), graveyard,
group layouts per frame, transient frames, overview, autolayout, hidden
windows, mode layouts, scenes, tile algorithms, winner, quit-restore, kill
fallback (two pickers), fill seams, list-mode (2,260), ibuffer (2,621),
switch (1,077; both files claim to be THE switcher), minibuffer with three
geometries.

The minimal set is eight concepts:

1. **frame**: one store. Fold `*frame-locals*` into the Elixir frame map or
   the reverse; delete set_frame_group_label/style.
2. **window**: leaf with `buffer, history, top, side, owner`. `side` replaces
   the class-string popup detection; `owner` replaces peek-window,
   listing-preview-target, detail window, collect window, group-preview.
3. **buffer**: `'group-ids` only; drop the chat-only `'group-id` split and the
   migration paths; `special?` derived from mode.
4. **group**: record + `'group-ids`. One MRU (Elixir state.mru already holds
   `{:group, g}`); delete `*group-mru*`, `group-mru-history-ids`, both cycle
   rings, tab-order. Graveyard = record with `killed-at`.
5. **window-configuration**: one value `(tree buffers points group)` with
   Emacs names. Replaces 12 restore mechanisms (~650 lines to ~120).
6. **one display rule table**: keep the chain. Peek, listing-preview,
   candidate, collect, switch, ibuffer, group previews and detail memory
   become one `display-preview` action: show NAME in the owner window of the
   asking list, never bump MRU, never take focus (~1,100 to ~250). Target
   layout and group pane choice become display actions (~350 to ~80).
7. **one arrange function**: `(window-arrange! SPEC)` over the mode-layout
   grammar; tile algorithms, autolayout, scenes, overview, target and
   adaptive layouts are spec producers (~1,000 to ~350).
8. **one list renderer**: list-mode with `'surface` (window, popup,
   minibuffer, modal). switch.scm, ibuffer.scm, the groups board, chat-list,
   collect, mb-rail, the group prompt rail and ibuffer-prompt! become a rows
   function each. Group rows are built four ways today. Elixir renders one
   row model for minibuffer, completion, transient, rail and list windows
   (~1,600 lines).

Commands: 160 in this domain to ~55. Families: 19 window-layout-*/
autolayout-* to `window-layout ALGO`; 7 overview-* to 0; 9 popup-* to
display-buffer + quit-window + scroll-other-window; 10 ibuffer sort/group
toggles to the list-mode verbs that exist; 12 switcher entry commands to
`switch-to-buffer` with 'scope and 'surface; 9 group-add variants to three.

State duplication: current group (3), membership (`'group-ids`, `'group-id`,
legacy `'group`/`'companion-of`, `group-members-index`, frame owner slot),
recency (7), window->buffer (Elixir tree + 8 Scheme parallel trees each with
its own dead-buffer sanitizer), popup identity (4 ways).

Elixir editor.ex duplicates Scheme: kill fallback then group repair;
other_window cyclic then Scheme focusable filter; preview_buffer as a second
entry point; group_label/group_color as a second store; restore_tree history
rules beside layout--restore-histories!.

Totals: ~15,400 to ~7,000 lines; docs/groups.md, WINDOWS.md,
DISPLAY-BUFFER.md, POPUPS.md, PEEK.md, GROUP-MODES.md, CHAT-LIST.md become one
WINDOWS.md.

### 4a. Rearranging windows takes seconds (first-class, ruled 2026-09-18)

A window change is a tree edit plus one hook. The Scheme suite marks 49
window-rearranging tests with 120-300s timeouts, and the bridge gives each
test 30s. Nothing in a rearrangement justifies more than milliseconds: the
silent-buffer rule already holds (per-command work only for the manipulated
buffer; the per-window dashboard sync was fixed).

Measured 2026-09-18 in the test VM (`SCHEME_TIMES=1 SCHEME_TESTS=...`,
then one call at a time):

| Operation | Time |
|---|---|
| split-window!, delete-other-windows!, switch-to-buffer! | 0ms |
| buffer-create, buffer-kill! | 0-2ms |
| every layout-policy, window, group-switch test | under 0.4s |
| ibuffer draw, 4 rows | 12-14ms |
| ibuffer draw, 24 rows | 43-47ms |
| ibuffer test fixture (open, set filter, refresh) | 135-141ms |
| one ibuffer test | 0.4-0.7s |
| tile-all-uses-only-the-current-project | 3.05s = its `wait-until` cap; the test fails in the dirty tree |

Rearranging windows costs nothing. The seconds in the suite are `wait-until`
caps on failing tests and the 30s bridge timeout on hanging ones. The real
cost is the table draw, and the interpreter is not the reason: a lambda
call, a buffer-local read, and an assoc over 100 entries each cost 1-2us.
The reason is per-draw facts recomputed per row. `ibuffer-fields` depends
on the buffer's grouping only, yet every row's cells asked it, at 0.28ms
a call: 7ms of a 49ms draw. Memoized per draw, the draw is 39ms and the
ibuffer tests run in 80-170ms instead of 400-700ms (the fixture also
draws twice per test now, not four times).

What is left in the 39ms for 25 rows: row fetch 3, column fit 5 (each
field measures every row once), prepare 8 (cells 3, lay-out 3, lines 2),
composml-text 9 (record fn 3, the loop 6), write and overlays 3, the rest
under 2ms each. Under 1ms per row needs one pass per row that builds
cells, lines, fields and record together instead of four passes; that is
the "one list renderer" item in section 4, not a micro-fix.

## 5. Agent, chat, LLM, tools, permissions

Scope: Elixir 6,534 (agent.ex, 5 backends, llm.ex, llm_session.ex, llmdb.ex,
model_catalog.ex, mcp, reactor, candidates, embedding_index); Scheme 12,853
in 19 packages + ~2,100 in editor.scm.

1. **Two conversation lanes still exist.** llm-mode (E:9926-10760, ~800) is a
   second runtime with its own session open, context fn, dispatcher, and a
   permission stub that answers 'allow. M-o becomes "send region to the
   group's chat".
2. **Four backends, one contract not enforced.** close/1, emit/2,
   adapter_exit, json_text, Port handle_info quads are byte-identical across
   acp.ex and codex_app_server.ex; 27 GenServer.call shims; 5 capability
   lists. `use Backend` defines the shims; a backend supplies
   start/prompt/translate.
3. **JSON-RPC framing written five times** (acp, codex, mcp/conn, lsp/conn,
   transport.ex) while endpoint/conn.ex already has exec+tcp transports with
   every framing. One JsonRpc over Endpoint.Conn (~450 lines).
4. **codex_app_server.ex is an ACP clone** (903 lines) with an English regex
   on a vendor message. Delete if codex-acp works.
5. **llm.ex + req_llm.ex + llm_session.ex are three modules for one lane.**
   `llm-with-tools` has zero callers; LLM.request is test-only;
   llm_session.ex is 20 pass-throughs; llm-session-* and agent-* primitive
   families (30) write the same escaped slot. One `agent-*` family (~12).
6. **The tool zoo grew back** (CQ W1): 25 define-tool! in 6 files, 22 of them
   restate a public! function one line above; model-facing tool lists are
   built five ways. eval-scheme + ask; apropos is a function the model calls
   through eval.
7. **Catalog metadata**: public! 1,042, effects! 545, domain! 327,
   catalog-meta! 258, category! 94 across 231 files; four runtime readers of
   effects; CQ #1 (strings vs symbols, so 258 entries never match) still
   stands. One docstring + one optional 'effects tag on the ~50 destructive
   functions.
8. **Apropos**: 850 Scheme + 368 Elixir + OpenAI embeddings to search
   docstrings. ~60-line grep over the catalog; keep BM25 if measured better.
9. **Permissions**: 14 concepts, an 8-arm policy, five Elixir
   implementations, one reachable decision. Default stance is auto; arm 5
   returns allow-always for `execute`; eval-scheme is '(write execute) so
   the effects verdict never fires for the one tool that matters; arm 1
   greps raw text for verbs. One `(permit? buf text) -> allow|ask|deny` over
   stance + deny-list; Elixir keeps resolve_permission and the ask UI.
   (CQ #6: raw text differs per lane, req_llm.ex:378, still open.)
10. **The config record exists six times**: connector, MCP server, preset,
    bundle, setup's program registry, workspace LLM defaults. `compos` is
    registered as an MCP server pointing at itself and special-cased out five
    times. One record `(name connector cmd model effort servers stance)` +
    one picker; llm-config.scm 951, setup.scm 713, mcp-hub.scm 419 mostly go.
11. **Twelve surfaces show one conversation**: chat-mode, *chat-list*,
    " *chats*", chat-switch-prompt (0 callers), chat-list preview (a fourth
    block renderer), *subagents* (0 non-test callers), *Chat Performance*,
    three sentry modes, llm-mode, scratch outputs. chat-mode + one ibuffer
    kind.
12. **Transcript primitives written twice, byte for byte**: chat-blocks-push!
    = agent-block-push!, chat-blocks-drop! = agent-block-drop-kind!,
    chat-render! = agent-render!, chat-clear-waiting! = agent-clear-waiting!
    over two locals, and chat-abort calls both. Turn->text in 3 places,
    flatten in 3, clip in 5, "find this chat's buffer" in 4.
13. **Elixir holds policy**: `<system>` wrapper (acp.ex:222), an English
    instruction sentence (codex:483), denial strings the model reads,
    "claude-sonnet-5" default, per-model context hacks, 40 retries on a
    string match, "*agent: slug*" buffer names, CLAUDECODE deletion.
14. **Dead and broken**: chat-dismiss defined twice, the winner calls
    `chat-dismiss--finish!` which exists nowhere; chat-list--preview-now! is
    a `#f` stub; ~25 zero-caller defs listed in the audit.
15. **sentry.scm** (954) is an HTTP client dressed as a subsystem; its API
    fns have zero external callers. ~120 lines the model calls via eval.
16. **worktrees.scm + jj.scm**: 75% agent ceremony, little reachable;
    jj-push exists to justify a deny-list carve-out.
17. **Prompt composition**: 330 lines + 111 of doc for 8.4KB of text; three
    lanes still splice differently. One `(chat-system-prompt buf)`.
18. **Title/summary/compaction** (~700): the file's own comment says
    compaction no longer pays for itself.

Target: Elixir ~1,600 of 6,534; Scheme ~4,500 of ~14,950. Order: config
record, permit?, tools + catalog, backend base + JsonRpc, one chat.scm,
llm-mode removal, sentry/worktrees/jj trims.

## 6. Packages

1. **Out of boot**: 15 personal apps, 6,634 lines, ~75 commands, 41
   defcustoms, 0 inbound users. They stay in `scheme/packages/` and leave
   init.scm; the user init opts in. calendar/ is
   not even loaded. org.scm (646) is superseded by morg. 1-commit imports
   untouched since 2026-08-29: db, endpoint, graphql, package, peers,
   training, web-server. ~7,300 lines and ~250ms of boot.
2. **Core depends on packages**: editor.scm calls 129 symbols from 28
   packages; 66 of ~100 files forward-reference later loads; init.scm
   ordering is enforced by comments; 28 packages re-stamp `package!` at top
   level; `message` is shadowed by messages.scm at boot slot 66 so two
   `message`s exist during boot. Declared `requires` derive the order.
3. **Builtin gap**: safe plist-get reimplemented 25 times; make the builtin
   return `#f` for a non-list. sh-quote copied 8 times. `--replace-buffer!`
   copied 5 times; add `buffer-set-text!`. String helpers (replace,
   html-escape, text, take, clip, first-line, basename) ~40 defines. Time
   formatting 7 ways. Exact duplicate bodies: 19 groups, 79 lines.
4. **App skeleton**: home-group!/enter-group!/join-group!/log! copied per app
   with 3 divergent behaviours (sentry sets a `'group` local instead of
   buffer-add-group!). Each app writes --rows, --cells, --meta, --columns,
   --narrow-cells, a refresh command, a detail buffer, a log buffer, 2-12
   registration forms. A `define-app` form removes ~150 lines per app.
   Browser-scrape apps share an unextracted page-poll loop.
5. **HTTP**: http.scm exists; 8 packages hand-build curl through
   shell-command->string (62 sites).
6. **Defcustoms**: 253; 24 have a non-default value; 88 are read at one site
   in their own file. Rule: a defcustom needs a second reader or a user
   story.
7. **Commands**: 264 unbound; 103 reachable only by M-x; ~60 look like
   leftovers (bookmark-* parity stubs x12, ibuffer-do-sort-by-* x3,
   agent-verbosity-* x3, chat-heal/unstick/derive-names, ...).
8. **Load-time side effects**: editor.scm 115, themes 64, groups 42, irc 36;
   perf.scm arms a timer at boot for a mode that is off by default. A package
   registers data and does nothing until its mode runs.

## 7. Primitive surface and Elixir modules

1. layouts.ex is 2,903 lines of JS + 1,780 of CSS in ~S strings; the Keys
   hook `mounted()` is one 1,326-line closure; key policy (CMD_KEYS,
   editingAfterKey, nativeTextKey) lives in JS. Static files; Scheme
   publishes the key tables as frame data.
2. Two LiveViews for one editor: mobile_live.ex + mobile_layouts.ex repeat
   mount/refresh/drain, 9 handle_event clauses verbatim, the modeline, the
   AgentScroll hook, 295 lines of CSS; the keys panel synthesizes C-n/C-p/RET
   presses. One EditorLive; Scheme picks the 'handheld layout profile.
3. Three Markdown renderers (markdown/html.ex, editor_live.ex:3112-4300 with
   an Earmark fallback, embed cards + oembed.ex). Markdown.Html owns the
   document; drop Earmark.
4. The view runs the text display engine (viewport_lines, build_static,
   display_spans, which calls Buffer.request_fontification; line_cache per
   LiveView process). Core Display returns rows per window memoized by
   version; both clients and /raw consume it (CQ: whole-buffer build_static).
5. "agent" is a special render mode across four layers (editor.ex agent_leaf
   reads 12 named locals; ag_block clauses; agent_transcript.ex; AgentScroll;
   122 .ag-* CSS rules) beside the generic "blocks" mode that renders any
   Scheme block tree.
6. Every primitive is registered twice (impl map + docs map: 900 lines);
   window-list-all is registered twice. One `prim("name", "doc", fn)` macro.
7. Google: 5 prims, a private Req wrapper, a private Bandit listener for the
   OAuth callback beside web_server.ex, a token refresh that is one POST.
   One `oauth2` prim; the callback page is a Scheme web-server handler.
8. Minibuffer and completion policy in Elixir: vertico-directory rule in
   minibuffer-del!, "fill input with the selected label", 5 completion
   styles, a window of 8, "SPC ends completion". The prompt is a buffer with
   a keymap; Candidates.matches?/rank stays as one pure prim (~400 lines,
   ~12 prims).
9. Landing policy in the Editor GenServer, then wrapped again in Scheme
   under builtin-* raw names (22 aliases): delete_window lands on first_leaf,
   other_window cyclic, set_window_buffer bumps MRU, kill_buffer recreates
   *scratch* and closes an llm session by reading a local.
10. The Editor GenServer builds the render payload (render_walk 205 lines,
    modeline_group formats "N groups" strings) and editor_live.ex adds its
    own header with hardcoded chords ("C-x C-f", "C-c a", "C-x w").
11. Per-subsystem list/detail/log/on-event families seven times
    (mcp-, lsp-, endpoint-, web-server-, db-, agent-, socket-) with three
    copies of strftime; nine single-slot handler registries. `(conn-list
    KIND)`, `(conn-detail KIND NAME)`, `(conn-log KIND NAME)`, `(on-event!
    KIND fn)`: 22 prims to 4.
12. Motion and word syntax in Elixir (12 prims, fixed word class). Keep a
    fast char/line primitive; forward-word etc. are Scheme with a
    mode-settable syntax.
13. Dual spellings: point/buffer-point, goto-char!/buffer-goto!,
    keymap-set!/define-key, buffer-set-hidden!/fold-set!,
    local-set-key/local-set-key*, minibuffer-read/minibuffer-read*,
    delete-window!/delete-window-id!, window-list/window-list-all,
    split-window!/split-root!. ~25 prims.
14. 52 registered names with no production caller (43 test-only, 9 none).
    SchemeActor (283 lines, 9 prims, a supervisor) has zero production users.
15. Three model catalogs (llmdb.ex downloads models.dev; model_catalog.ex
    reads the llm_db hex package which IS that snapshot; llm.ex receives
    total_cost from req_llm). The LLMDb vs LLMDB name collision is the open
    llmdb-max-tokens bug. ModelCatalog over LLMDB; keep a ~60-line usage
    ledger.
16. Two PTY runners over /usr/bin/script (proc.ex, terminal.ex); prims
    dispatch on Terminal.running? for every call. One Terminal; comint is
    Terminal with raw: false.
17. Dired presentation in Elixir: file-stat returns "17.3M" and "Jan  5
    14:02"; file-mtime and file-size exist because file-stat cannot be
    sorted. One file-stat returning numbers.
18. Small twins: four telemetry collectors with four stores; two FileSystem
    watchers (watch.ex, hotload.ex) each with debounce; three shell spawners;
    remote-* prims are shell-command->string with an ssh prefix; irc.ex +
    2 prims for one package; embedding_index.ex posts raw Req to OpenAI
    while req_llm ships embed/3; MCP-over-HTTP hand-rolls SSE beside an
    Endpoint {:http, url} transport.
19. homepage_live.ex (1,355) is a marketing site for three brands with no
    core calls. Static HTML or out of the repo.
20. Fourteen primitives each re-implement the sync/async fork with their own
    timeout constant. Every blocking prim is sync; Scheme wraps it in
    task-run! when it wants a callback.

## 8. Runtime: buffer, session, editor, execution model

1. 32 GenServer modules, 12 Registries, 11 DynamicSupervisors; ten
   Registry+DynamicSupervisor pairs are the same pattern. One
   `Compos.Core.Children`.
2. `:compos_escaped_closures` (95 references) holds six unrelated things:
   command GC roots, reactor callbacks, debounce timers, eval-defer tokens,
   task callbacks, the last 32 eval results. It is the Scheme heap roots
   table; name and type it as one.
3. ~14 files under ~/.compos from Elixir and ~30 more from Scheme, no owner
   or manifest.
4. **Eleven ways to run Scheme**: lanes, :single_actor (one test + a config
   line), SchemeActor (copied env), SchemeTask, task-run!, eval-defer!/
   eval-resolve!, with-scheme-lock, wait-until polling, debounce!, Reactor
   Tasks, SchemeReadLimiter. The two-tier Env with escape/promote/flush, the
   Session frame GC walking every buffer's locals, SchemeHeap,
   SchemeRawNames, and the stale-frame retry loops exist because many BEAM
   processes mutate one Scheme world. Minimal: one serial process per lane +
   SchemeTask for pure reads. If one serial world is adopted, env.ex (546) +
   gc.ex + roots + flush + heir dance collapse (~900 lines). Largest and
   riskiest item; needs a `:ui` latency benchmark under an agent turn first.
5. **Attribution recorded three times** (Loro commit actor, authors spans +
   origins, edit_log capped at 500 and not persisted); pending_ops batch
   fields for a SQLite store that no longer exists; the moduledoc still
   promises it. Loro is the only author record (~650 lines).
6. **Text held twice**: rope + Loro doc mirror every edit, `verify_history`
   compares them at every checkpoint, the checkpoint stores the text again
   beside the Loro snapshot. Either the doc is the text or the doc waits for
   multiplayer.
7. **Five persistence mechanisms per buffer**: checkpoint etf, catalog.etf
   (with a copy of every local under 1KB), Loro log, desktop.etf, BufferView
   ETS row rebuilt at boot. The catalog is rebuilt by scanning checkpoints,
   so it is a cache pretending to be a store. One file per buffer = Loro log;
   catalog derived at boot; desktop = window trees + Scheme globals.
8. **Four read paths for one field** (ETS row, GenServer call, dormant
   checkpoint read, BufferStore fact/local); `Buffer.point/1` tries three.
   The row is the only read model for live and dormant buffers.
9. Display and command-loop state in the model struct: fontify task/cache,
   ts, goal_col, insert_run, undo_run; hidden, narrow_range, overlays are
   three tagged-range maps adjusted by the same function. One `ranges` map.
10. **Session.ex is a second primitive table**: 2,300 of 3,341 lines are
    primitives and connector glue; hot-reload logic (250 lines) lives here
    while Hotload only watches. Each connector exports its own primitives;
    Hotload.Scheme owns reload; Session keeps eval/exec/GC (~700 lines).
    Registering primitives by module+name makes a code swap self-healing and
    deletes SchemeRawNames.
11. Messages stored twice (ETS ring + *Messages* buffer). The buffer is the
    log.
12. **Keymaps**: 14 prims, ~30 handle_calls, 360 lines of ladder resolution
    in editor.ex while key_dispatch.ex says "what keys mean is Scheme's
    business". Keymaps are Scheme data; Elixir keeps one lookup.
13. MRU three ways; clips/navigations/selects are three identical take-once
    slots; faces in four places; undo_exempt is a per-command property that
    belongs in catalog meta.
14. **Observability**: Telemetry + telemetry.scm, SysMon + perf.scm (500
    lines of hand-rolled SVG), Profiler + profile.scm (VM-wide counters),
    live_dashboard, Lane slow-job Logger beside the telemetry row, ChatPerf
    jsonl, llm-usage.jsonl, KeyDispatch trace. One bounded event stream +
    one sample + one Scheme buffer (~2,000 lines).
15. **Seven code paths wake a buffer** with a 3-way branch on the caller's
    process kind and a pdict flag; the four-condition eviction guard is
    written twice. `wake(name)` = start from Loro log + one Scheme
    `buffer-woken!` on the buffer's lane, always async.
16. `Desktop.upgrade` and `Buffer.upgrade` run on every message; desktop v1
    beside v2/v3; use code_change/3 once.
17. compos_scheme is clean: no editor knowledge; stale moduledoc only.
18. Named leftovers: events broadcast twice for a "compatibility alias";
    "legacy" actor kind; read_many_fallback; the Buffer moduledoc describes
    list-of-ropes undo and a SQLite store.

## 9. Tests, docs, skills, cruft

1. 43 `*_scheme_test.exs` wrappers (1,961 lines) duplicate
   `scheme_suite_test.exs`, which already runs every priv/tests file; two
   name Scheme files that do not exist.
2. 40 features tested in both suites (~7,800 ExUnit lines); 104 ExUnit files
   only call Session.eval (11,205 lines): Scheme policy in Elixir clothing.
   editor_test.exs (4,643): dired, switcher, display-buffer, tiling describes
   are Scheme policy with Scheme suites.
3. 7 FakeTransport copies; `eval!` in 144 files; `press` in 66; `wait_until`
   in 20. Three ways to fake an LLM turn; four ways to get a second daemon.
4. 61 files assert production chords; 28 press C-x/C-h/M-x; 14 of the 24
   always-red tests are named after a chord.
5. ~3,500 lines of tests for demo apps (doom, spreadsheet, pdf, google scene,
   chrome, evil, whatsapp, amazon, irc).
6. KNOWN-FAILURES.md lists 64 names from 2026-08-23; nobody re-measured.
7. Docs: 19 current specs; stale: HANDOFF.html (2026-08-14, wrong repo path,
   still the CLAUDE.md entry point), ROADMAP, KNOWN-FAILURES,
   PERFORMANCE-REVIEW; superseded: doc/WINDOWS.md, training.md vs LEARN
   COMPOS.md, COMPONENTS-SPEC, CONTROL-SPEC, PROVENANCE + BUFFER, four
   COMPOSML docs; never built: ANNOTATIONS, PDF-ANNOTATIONS,
   EDITING-SURFACE-SPEC, ORG-MODE-PLAN, SIMPLIFY-SPEC (has `pkill`),
   CLEANUP-QUEUE, SCHEME-TEST-MIGRATION, SWITCHER-PERF-HANDOFF. The essays
   (BEYOND-TOOLS, CORDIS-VS-EMACS, EMACS-AS-AGENT-HARNESS, INTRODUCTION,
   COMPOS-HOMEPAGE-BRIEF) stay in docs/ (ruled 2026-09-19). Dangling: AI-NATIVE-SPEC, INTERFACE, SCOPE, LISP,
   ACP, calendar. Non-doc files: 7 png, a patch, a saved chat transcript.
8. Skills: 12 to 5. code-change says "do not read CLAUDE.md as a ritual"
   while CLAUDE.md says load code-change before every change. compos-boot
   and compos-restart both carry the COMPOS_VERIFY recipe; compos-debug and
   bin/compos default to `~/.compos-web`.
9. Root cruft: `-`, `touched`, editing.png (3MB), image.png, demo.org,
   budget.sheet.json, boards/*.tldr, doc/WINDOWS.md (kept by an explicit
   .gitignore line), three mix-generated READMEs, two erl_crash.dump,
   burrito_out/aimax_macos_arm, 7 stale worktrees (1.8GB, still registered),
   the ai-max.el symlink and worktree.
10. Naming: source is clean; aimax/ai-max/cordis survive in
    .claude/settings.local.json, skills.scm:291 (`cordis.patch.yml`),
    docs, and build dirs.

## 10. Order of work

Each step lands alone and leaves the tree green.

**Done 2026-09-18:** load-path (9a1ca5bb), the 40 test wrappers (316ab4a5),
plist-get and its nine wrappers (9e74f0e8), the secrets seam (7640482e),
SchemeActor + single_actor + six unused primitives (7ac0c748). A recount
with Elixir eval strings, user config, skills and prompts in the corpus
found 20 unreferenced primitives, not 52; introspection reads that tests
use to assert state (face-list, keymap-parent, buffer-local-map, lsp-log,
task-alive?, unbind-global!) stay. One test support module (b59e22e6):
96 files use Compos.Case, one FakeTransport; 31 files keep a custom helper.
The package move (0e96750d): 92 packages in scheme/packages; agenda,
agent-transcript, annotate, appearance, diff-mode, paredit wait in
priv/packages for another session's commit, then one rename and the
priv/packages entry leaves load-path. Then: the last six moved (19ba0452);
fourteen apps left the stock boot (8024a266); one primitive registration
with the doc in the key (item 7.6, the fix for CQ's double registration).

**Also done 2026-09-19:** docs sweep (cd4575aa), eight shared builtins +
buffer-set-text! (a1c82b9c), eight more wrapper tests (next commit), one
JSON-RPC framer for ACP, Codex and MCP stdio.

**Also done 2026-09-19, later:** 45 single-reader defcustoms demoted
(d9c3365b); one model catalog, LLMDb gone, ledger = LLMUsage (43b02bb9;
the provider-blind max_tokens bug went with it); `use Backend` supplies
the six required client shims. Not done, with reasons: the two
FileSystem watchers are not one thing (Watch is content-free by contract,
Hotload needs paths); the two PTY runners wait for a measured reason;
the double-covered Elixir tests stay where they hold key-dispatch or
Elixir-API assertions the Scheme twin lacks.

**And later still:** the twelve restatement tools are gone, the toolbox is
the ten llm_tools_test names (item 5.6 W1); the MCP, LSP, DB, endpoint,
web-server, browser and LLM-session primitives register from their own
modules and the reload logic is Hotload.Scheme, so session.ex is 2,100
lines from 3,341 (item 8.10, 8.12); one JSON-RPC framer; docs/KNOWN-FAILURES.md
is rewritten from measurement. Landmine met on the way: the colocated jj
working copy rewrote the git index and 26 package files fell out of HEAD
for six commits; repaired in d867255d, recorded in memory.

**Red before today, measured by running the pre-change file** (for the
KNOWN-FAILURES rewrite): agent_test 36 of 52; ChatResetTest, SwitchTest,
PresetTest 17; MovieTest, ChosenPaneTest, SpotifyTest 1 each; TransientTest
2; WriteFileTest "C-n then RET"; ProjectSearchTest 4; LLMToolsTest 3;
ChromeTest "returning from a page"; LoadTest was red on calendar. Scheme:
the keymap ladder tests, the block and theme tests, a-page-opens when feeds
runs first, and the four apropos tests.

**State after Phase 1 (2026-09-19, second autonomous run).** editor.scm
is 5.6k lines, from 15.3k. Thirteen sections are packages (tabulated-list,
window, tramp, chat-mode, modeline, isearch, capf, visual-line, collect,
comint, transient, chrome, and dired stays in priv but loads from
init.scm). One catalog, one mode table, keyed hooks for every registry
and seam, defvar with persist, the alist and plist builtins, sh-quote as
a builtin, the block files without their prologue dance. Every failure
seen on the way is in docs/KNOWN-FAILURES.md with the HEAD it was
measured at. What remains, and why it waits:

- Rulings: the five keys bound in two files (C-x b, C-_, C-t, C-c RET,
  RET); merging y-or-n into y-or-n-p (23 sites); the sentry.scm cut and
  one PTY runner (something a person runs today).
- Phase 2 (section 4 and 5 designs: the window domain, the chat and
  llm-mode merge, the agent config record) touches files another session
  holds and changes behaviour; it needs its own plan and a green baseline
  for the layout tests, which are red at HEAD today.
- One-shot boot migrations (llm-bundles-assign-keys at load, the chat
  record and input migrations on restore) want one desktop migration
  pass with a cut-off; themes.scm's face restatements and the 22
  unreferenced face aliases want a measurement of the CSS side first.
- Phase 3 (runtime) and Phase 4 (the execution model benchmark).

**Later on 2026-09-19:** the LSP client speaks through the shared JSON-RPC
framer (four of the five framers are one now); ChatPerf is gone;
chat-dismiss works again and nine dead definitions went; 25 redundant
package! stamps went; one clock for the connection logs. Checked and left
in place, with the reason: the buffer batch fields serve the public
buffer-provenance-start! primitive (item 8.5 was wrong about that); the
bookmark commands are two-line delegations, not stubs (6.7 was wrong);
display-memory-mode is on by default, so its boot timer is right (6.8 was
wrong).

**Phase 1, started 2026-09-19.** One catalog (b39191ca): define-command
and public! write one table, `*command-fns*`, `*command-names*`,
`*public-api*` and `*public-keys*` are gone, and `public-api` is a view.
Twenty dead definitions and the shadowed preview block went (b5302dd4).
One mode table: `*modes*` holds every fact about a mode as a plist under
its name, `mode-put!` and `mode-get` read and write one fact,
`mode-inherited` walks the parents, and `(define-mode NAME SETUP 'parent P
'doc D 'icon I 'minor #t 'teardown T 'keymap K)` takes every fact in one
form. The seven side tables (`*mode-setups*`, `*mode-parents*`,
`*mode-docs*`, `*mode-icons*`, `*mode-link-syntaxes*`, `*mode-layouts*`,
`*mode-headlines*`), `*dismissible-modes*` and `*minor-mode-setups*` are
gone; the old setter names stay as one-line doors, so the 160 callers did
not change. `plist-put` is a builtin beside `plist-get`, and the 49
copies of the alist upsert idiom are `(alist-put TABLE KEY VALUE)`; the
alist builtins step over an empty entry. Landmine met: a Nerd Font glyph
is invisible in a terminal, and a rewrite typed from the screen replaced
twelve mode icons with empty strings; the fix was a script that copied
them back from HEAD. Read a glyph line with `unicode_escape` before you
retype it.
Keyed hooks: `(add-hook! '(block-click diff) FN)` holds one function per
key and the same key replaces, so the six keyed registries
(`*preview-link-verbs*`, `*lsp-event-handlers*`,
`*input-intent-handlers*`, `*endpoint-event-handlers*`,
`*block-click-handlers*`, `*agent-turn-end-handlers*`) and their on-X!
setters are gone, the five older spellings (on-fs-change!,
on-buffer-created!, on-buffer-woken!, on-buffer-renamed!,
on-buffer-shown!) are gone, and the `boundp` guards in front of them went
with them. The four one-function-per-key registries (`*marginalia*`,
`*context-providers*`, `*target-providers*`, `*display-buffer-actions*`)
are keyed hooks too, behind their old setter names. docs/HOOKS.md lists
the keyed hooks. Left as they are, with the reason: `*embark-actions*`
holds a list of actions per type, not a function; `*paste-hooks*` keeps
registration order and replaces in place, which a keyed hook does not.
Still to do in this item: the re-`set!` seams and the remaining boundp
guards.
Sections out of editor.scm, first move: the tabulated list (2,014 lines)
is `scheme/packages/tabulated-list.scm`, the first load in init.scm;
dired.scm reads the list registry at load, so it left the Elixir
bootstrap list and loads second from init.scm. editor.scm is 13,147
lines. The move is a cut: no definition changed. Rule for the next
moves: cut on a section header, check that nothing outside the block
names a block definition at load time (a top-level call, or the value of
a `define`), and put the new file in init.scm ahead of its first caller.
Second move: the chat buffer, the LLM pipes, the chat locals lists, the
.chat format, the backends and the C-c b setup (2,185 lines) are
`scheme/packages/chat-mode.scm`, loaded third from init.scm; the block
had inherited the terminal section's catalog scope (domain processes),
so the file now declares domain chat. editor.scm is 10,962 lines.
Third move: the modeline dashboard and the buffer-name grammar (1,219
lines) are `scheme/packages/modeline.scm`, loaded fourth; desktop-skip!
stayed in the kernel beside its callers in the buffer cache. editor.scm
is 9,744 lines.
Then: the list-mode definers (define-list-mode!, list-mode-init!,
list-mode-show!) joined tabulated-list.scm, the cost commands joined
chat-mode.scm, and the public! and catalog-meta! lines of every moved
definition moved into its file under the catalog scope they had; three
global bindings that rode along came back. editor.scm is 9,482 lines.
Fourth move, four files at once: collect.scm (embark-collect), comint.scm
(term-mode, comint-shell-mode, tail-mode), isearch.scm (isearch, lazy
highlight, hl-line, replace) and capf.scm (completion at point). The cut
script keeps each block's ambient catalog scope: it writes the scope in
force at the block's start into the new file and restores the scope the
block left behind at the cut point. editor.scm is 8,707 lines. The mark
ring and font-lock keywords stay: the first is an Emacs mechanism, the
second is called from set-mode!.
Fifth move: the window domain (display-buffer, popups, the look, peek,
mode layouts, the pool, special-mode, winner, the window questions,
tiling: 2,540 lines) is `scheme/packages/window.scm`, loaded second
because a list mode derives from special-mode at load; visual lines are
`visual-line.scm`. editor.scm is 5,964 lines. What stays and why: the
catalog, define-command, the buffer cache, editing and the kill ring,
the minibuffer and completing-read, hooks, variables, marginalia, hot
reload, modes and minor modes, savehist, buffer waking, renaming and
detaching, the name at point, providers and embark, motion, capf's
callers, scrolling, the mark ring, font-lock (set-mode! calls it),
files and write policy, load-path, delete-file, the remote and visit
block (visit and find-file live in it), M-x and eval, the prefix maps,
self-insert, the movement state, input intents, buffer links, daemon
control and the default keymap.
Sixth move: the remote half of the file block (remote-ls, remote-sh!,
the file operations that branch on /ssh:, remote-visit) is
`scheme/packages/tramp.scm`, loaded before dired; visit and find-file
stay in the kernel under their own header. editor.scm is 5,685 lines.
Landmine met: the test home keeps files between runs, and a note.txt a
run left on 2026-09-15 turned a plain write-file test into an overwrite
question; the fresh-dir helper now empties its directory first.
One defvar with persist (item 7, second half): `(defvar '*x* DEFAULT
'persist #t)` registers the desktop global itself, keyed by the name
without its stars, and a restore puts the saved value back or the
default. Seven of the fourteen persist-global! pairs are one line now;
the seven that normalise or rebuild on restore (llm-config-history,
llm-bundles, group-mru, groups-v2, hidden-windows, layout-targets,
and the composite ones) keep persist-global! as the door.
The re-set! seams are gone (item 8, the rest): candidate-face-for,
find-file-group-reader, buffer-project-label, buffer-workspace-label,
buffer-project-root, buffer-kill-repair and switch-buffer-source are
functions that ask a keyed hook and fall back to their old default, and
window-state-changed! runs window-state-change-hook; the packages that
used to set! them add a hook under their own key. docs/HOOKS.md lists
them. Item 8 of section 3 (24 commands with no key and no caller):
recounted after the moves, editor.scm has 6 commands nothing names
(desktop-clear, buffer-rename, display-line-numbers-mode, write-rules,
delete-file, load-file); they are M-x vocabulary with Emacs names and
stay. Left in the item: the seven boundp guards in editor.scm, all
call-time guards for optional packages.
Item 8 of section 3, the guards: 84 boundp guards on names that a stock
package always defines went from function bodies (an sexp-aware script
in the scratchpad: `(when (boundp 'x) BODY)` is BODY, `(if (boundp 'x) A
B)` is A, `(and (boundp 'x) REST)` is REST). 61 remain: guards on
opt-in packages, on names nothing defines (dead branches), the
reload aliases (raw-write-file!, raw-buffer-save!, buffer-kill-raw!),
and top-level `unless` forms that define when missing. The dead C-x b
line in editor.scm went; switch.scm's binding was the live one. The
C-_ and C-t overrides are deliberate per their comments (undo keeps C-/
and C-x u), so they stand.
Item 16 of section 3, second half, checked and left: the 37 Emacs face
names in themes.scm are `defface!` forms that inherit a compos face, and
the section's own comment says they exist so a package written for
Emacs finds font-lock-keyword-face; a reference count does not decide
an API surface. The four palettes restate the ts faces because
load-theme writes only the faces a theme names, as the paper palette's
comment says; a base palette with overrides changes that contract and
waits.
Section 5 item 15, sentry.scm: the owner keeps M-x sentry; the list,
detail and events buffers, their verbs and their three modes stay.
Item 16 of section 3, first half: transient.scm and chrome.scm are
packages in scheme/packages, loaded from init.scm (transient first, a
package defines its prefixes at load; chrome after dired, sentry and
code read it at load). The Elixir bootstrap list is editor.scm,
themes.scm, init.scm.
Item 13 of section 7 (dual spellings), checked: of the nine pairs only
two were the same function under two names. keymap-set! (define-key)
and buffer-set-hidden! (fold-set! without a tag) are gone. The other
seven differ in what they take: the current buffer against a named one
(point, goto-char!, local-set-key), the selected frame against every
frame (window-list), the active window against one by id
(delete-window!), the window against the frame root (split-window!),
and minibuffer-read against its handler-alist form; they stay.
Item 13 of section 3 (reimplemented builtins): take-n is the take
builtin (36 sites), transient--put is plist-put, list-tail-n is
list-tail, abbreviate-home is abbreviate-file-name; nth stays as the one
Emacs-named line over list-ref. name--trim-left and name--trim-right
looked unreferenced but are passed as values, so they stay. Item 15
(keys bound from several sections): the duplicate M-< and M-> lines
went. Five keys are bound in two files and the later file wins; these
are policy and wait for a ruling: C-x b (switch.scm ibuffer-prompt over
switch-to-buffer-prompt), C-_ (appearance.scm text-scale-decrease over
undo, the Emacs binding), C-t (telemetry.scm telemetry-toggle over
transpose-chars, the Emacs binding), C-c RET (chat-companion-ask and
goto-address-at-point), RET (preview.scm preview-newline over
newline-or-send). Item 5 (prompt doors), checked: read-char takes any
key and read-char-choice a key from a set; y-or-n takes two thunks and
y-or-n-p one continuation; yes-or-no-p takes a word. They are four
readers, not five copies. Merging y-or-n into y-or-n-p means rewriting
23 call sites; it waits.

**Phase 2, item 5.9, first cut (2026-09-19):** the one permission
decision is a function, `(permit? BUF TITLE KIND RAW)`, and the ACP
lane, the direct lane, the MCP proxy and the restart-daemon command call
it by name; the variable that held a lambda and the boundp guards around
it are gone. The nine Scheme tests that specify the policy pass. The
rest of 5.9 (fewer inputs to the decision) drops tested behaviours
(profiles, the effects verdict, Always rules) and is a ruling.

**Phase 2, item 5.10, measured (2026-09-19):** the config record does
not exist six times. The bundle in chat-mode.scm (connector, model,
effort, presets, permission, agent-mode, prompt-disabled, setup) is the
record, with 30 accessors and a normaliser for older desktops; the
connector "record" is six read accessors over the connector table; the
MCP server list is one plist; setup.scm asks one predicate; the
workspace defaults are four lines that read a bundle. What the item
really names is mcp-hub.scm, a 382-line list view with 13 commands over
the MCP servers, and llm-config.scm's 951 lines of pickers over the
bundle. Both are surfaces a person uses; folding them into one picker
is a design and a ruling, not a cut.

**Phase 2, item 5.1, measured (2026-09-19):** llm-mode is not a stray
second lane. code-agent-mode turns it on in a code buffer, writing-mode
turns it on in the document's scratch, scratch.scm copies it to a
scratch, the MCP proxy targets the buffer that wears it, prompts.scm and
the buffer lifecycle reset its runtime, and M-o, M-|, C-c m and C-c b
are its keys; ten test files specify it. Removing it means redesigning
code-agent-mode, the writing scratch and the proxy's target rule, and
deciding where an inline answer goes. That is the chat merge (5.1, 5.11,
5.12) as one project, and it is last in the Phase 2 order for that
reason.

**Phase 4, measured (2026-09-19).** The benchmark is
apps/compos_core/test/bench/ui_latency_bench.exs. A stub agent streams
1,500 chunks into its chat in one turn; 300 evals of `(+ 1 1)` run on
the :ui lane during the turn, 60 more queued on the chat's own buffer
lane, and 300 on :ui with nothing running. Three runs, microseconds:

| series | p50 | p95 | p99 | max |
|---|---|---|---|---|
| :ui, idle | 10-11 | 22-26 | 49-119 | 256-479 |
| :ui, under the turn | 11-12 | 25-36 | 35-88 | 53-1,393 |
| the chat's buffer lane, under the turn | 10-13 | 38-43 | 9,243-10,282 | 979,167-986,663 |

The lanes do their job: a :ui eval under a streaming turn costs what it
costs idle. The 0.99 s on the buffer lane was one job, and timing the
turn-end handler step by step found it: the first `chat-should-compact?`
of the VM decodes the bundled LLMDB snapshot (942 ms) inside
`llm-context-limit`, on the chat's own lane, in front of every keystroke
queued there. The boot warmup task decodes the catalog now
(ModelCatalog.warm), and a batch is bounded to 200 events as well as to
the 25 ms frame. After the fix, the same runs:

| series | p50 | p95 | p99 | max |
|---|---|---|---|---|
| the chat's buffer lane, under the turn | 13-15 | 49-59 | 3,448-3,730 | 9,673-11,910 |

A keystroke queued behind a streaming render now waits at most ~10 ms,
and the turn-end costs 3 ms. On this evidence one serial Scheme world is
within reach: the worst wait behind a burst is a frame, not a second.
The collapse of env.ex, gc, roots, flush, the heir dance and the retry
loops is Phase 3 proper, and this benchmark is the gate it runs against
before and after.

**Phase 3, checked (2026-09-19):** item 16 (the per-message
Desktop.upgrade and Buffer.upgrade) stays: Hotload swaps a module without
code_change/3, and the upgrade is what lets a running process read its
old state under the new module (editor.ex says the same beside its
take-once slots). The Buffer moduledoc and two comments that still
described a SQLite store now describe the Loro log. read_many_fallback
is the miss path of the row cache and stays. What is left of Phase 3 is
the four rewrites (one store, one read model, one wake path; Scheme
keymaps; one Display row model and one LiveView; one event stream) and
the world collapse behind the Phase 4 gate.

**Ruling 2026-09-19 (the owner): mcp-hub stays.** The hub is the inventory
of the MCP servers the system can run; a bundle is a selection from it.
Two roles, two surfaces. Item 5.10 keeps both and collapses the record:
one server table that the hub, the bundle picker, setup's program
registry and the workspace defaults all read, and a bundle names its
servers by name instead of carrying a copy of each.

**Item 5.10 closed by measurement (2026-09-19).** Under the ruling above
the code already has the shape it asks for: `*mcp-registry*` in mcp.scm
is the one server table; mcp-hub reads it directly (mcp-hub-names,
mcp-hub-spec); a preset is a named set of server names; a bundle names
presets; the workspace defaults hold a bundle plist; setup.scm asks one
predicate. No copy of a server record exists to collapse. The two
"compos" special cases are the editor bridge, whose tools are not an
MCP server on the wire, and they stay. Nothing to do.

**Ruling 2026-09-19 (the owner): llm-mode stays and is the lane.** The
gptel model: you talk in the buffer you are in, and the reply lands
there. A chat is a buffer in llm-mode. Item 5.1 inverts: the merge folds
chat-mode onto llm-mode (the transcript blocks, the tools, the ACP
backends and the permission ask become what llm-mode does in a chat
buffer), and llm-mode handles both chats and documents. Wanted later: a
gptel-like `C-u M-o` that directs the output (at point, to the group's
chat, to a new buffer, over the region). Nothing in-buffer goes.

**The chat merge, the plan (2026-09-19, agreed in outline):** the
transport is the chat runtime, one session, one backend, `permit?`, the
tools, the record. A document that talks gets a companion chat, one per
buffer, made on the first M-o and hidden until opened; it is the
conversation of record for that document, and the group chat is not
touched. Where the reply lands is a render target: plain M-o renders the
turn into the document at the mark, gptel style, and `C-u M-o` picks the
target (at point, the companion pane, a new buffer, over the region).
llm-mode keeps its prompt and response faces, the mark that chases
edits, C-g abort and M-| for a region; it loses its own dispatcher,
context function and permission stub. Steps: (1) llm-mode sends through
the companion, rendering unchanged; (2) the companion's turn-end feeds
the in-buffer render from the record; (3) `C-u M-o` targets; (4) the
llm-mode dispatcher, context fn and permission stub go; (5) 5.12's twin
transcript primitives collapse onto one set.

**The layout tests, bisected (2026-09-19).** The same six files at three
commits: fc980588 (the other session's last commit, before Phase 1) 27
red, 015d9a50 (the catalog, the mode table, the keyed hooks) 25 red,
9b0e7411 (the tabulated-list move) 24 red. The one name red later and
green at fc980588 is a-target-layout-does-not-give-one-mode-two-panes,
which passes alone and flips with order. Phase 1 did not turn the layout
tests red; they were red before it, from the listing-preview and target
layout work in flight. The editor's layout works after a restart; the
owner reports it slow, which is section 4a's first-class defect and is
measured before it is named.

**Wanted later (owner, 2026-09-19):** a hot refresh that unloads and
loads all Scheme, so a registry migration does not need a restart.

**4a, the slow layout prompt, found (2026-09-19).** The rows named it:
every arrow in the layout prompt cost 100-140 ms per chat pane in
EditorLive's decorate, with `hit false` on the agent block cache and
575 blocks re-rendered. The cache was keyed by window id, and the tiler
hands window ids out by leaf order, so after one move the window held a
different chat than the entry and every block re-rendered, markdown and
all. The agent and block caches are keyed by buffer now and die when the
buffer leaves the tree. On the way: the prompt applies a candidate to
the visible panes without restoring first, the refresh row names the
slowest leaf, and the slow-job log names the callback.

**Ruling 2026-09-19 (the owner): unify the transport; a document's chat is
a hidden chat you can ask to see.** Step 1 of the chat merge is in: an
M-o session answers a permission through `permit?` under the document's
stance, on both lanes (the direct lane's permission function and the
ACP-lane permission event). An `ask` is a y-or-n question in the
minibuffer, because the hidden chat has no pane for a card; a refusal is
silent. The allow-everything stub is gone. Step 2 is in: the first M-o
in a document makes `*chat:<document>*`, a real chat buffer attached
through chat-attach-agent! with the document's connector, model,
presets, directory and stance, hidden until `M-x llm-companion-show`.
The document's session is that chat's; the document still builds the
wire from its own text and the chat records the turn; the chat's event
handler forwards every event but the permission to the inline render,
and an ask in a hidden chat is a y-or-n question in the minibuffer.
The `inline-N` sessions, the inline event handler's own session open
and the permission stub are gone.

**Step 3 is in (2026-09-19): `C-u M-o` picks where the reply goes.** The
send menu (`llm-send-to`, a transient over the document) offers four
targets: at point (the bare M-o), in the document's chat shown in the
other window (`llm-send-chat`: the same send with no inline render), in
a new document shown in the other window (`llm-send-new-document`: the
prompt is copied into `*llm:DOC*`, which is an llm-mode document with a
hidden chat of its own), and over the region as a rewrite (`llm-rewrite`).
Every target talks through a hidden chat; only the landing differs.
Tests: llm-insert-test.scm, three deftests, through the stub backend.

**Step 4 is in (2026-09-19): the inline registry is gone.** The live
inline turn is data on the document's chat: `'inline-turn` (a runtime
local: the response block, the insertion point, the context size, what
arrived, the error) next to `'inline-target`. `llm-inline-events!`
stays as the document render, fed by the chat's event handler, and reads
the chat; the global `*llm-inline-sends*` table and the two closures per
send (completion, chunk) are gone, so a send is one call with data. The
document's context function (`llm-context-text`, the narrowing range)
stays: it is the document's wire, and a chat has no such range.

**5.12 is in (2026-09-19): the transcript primitives are one set.**
chat-blocks-push!, chat-blocks-drop! and chat-clear-waiting! are gone;
their callers use agent-block-push!, agent-block-drop-kind! and
agent-clear-waiting!, which now takes the buffer (the buffer is the
identity; a slug caller passes the buffer it holds). The 'chat-waiting
local was never set anywhere and is gone from chat-runtime-locals.
chat-render! and agent-render! stay: they are not twins. agent-render!
inserts through the runtime, so the edit's source is `{:agent, slug}`
and provenance names the agent; chat-render! inserts as the editor, for
a chat with no runtime (a restored chat, a REPL result, a summary).
Attribution: the same test files at HEAD 4f0a0be9 in a worktree fail
by the same names (chat_reset_test, llm_tools_test, the two excision
tests), so the collapse adds no red. The chat merge is complete.

**Item 14 is in (2026-09-19): one migration pass with a cut-off.**
scheme/packages/migrations.scm holds the registry: `(define-buffer-migration!
NAME SINCE FN)`; `migrate-buffer!` runs on `buffer-restore-hook` (the
kernel runs it in restore-buffer-runtime! before the mode setup) and
stamps the buffer's persisted 'migrations local, so each migration runs
once per buffer. A migration lives 90 days from SINCE, then goes with its
test; M-x list-migrations shows the dates. Registered: chat-record
('chat-turns to the record), chat-companion-group ('companion-of to
'group), chat-input-marker (the marker bytes; it also finds a missing
mark from the last marker, so chat-attach! no longer migrates), and
shell-mode-name (shell-mode to term-mode; the shell-mode alias mode and
its icon are gone). The hot-reload re-assignment of bundle keys at load
is gone; the persist-global! reader still normalizes. Left in place: the
'llm-responses mirror (five writers keep the old range local current for
a list-row count and a legacy fallback; it is a mirror, not a one-shot,
and goes with the llm-mode block cleanup). Tests: migrations-test.scm.

**Item 17 (2026-09-19): one fence finder.** morg-scan is the fence-aware
line scanner; markdown-mode, morg, llm-mode and now preview read fences
from it. preview.scm had the fourth finder, a parity count of backtick
lines over the buffer prefix on every RET; preview--literal-line? now
asks the scan entry at the line (open, close or code). web--fence-command
is not a finder (it names the command for a fence language). The
load-bundled-package expansion in init.scm is gone already; the block
files' prologues are file headers and stay.

**Item 16, the faces, measured (2026-09-19).** themes.scm names 63
faces. The UI makes `.f-NAME` and `--NAME-ATTR` from every face
(face_css.ex), and a tree-sitter capture head becomes the face `ts-HEAD`
(editor_live.ex). The seven installed grammars emit these heads:
punctuation, operator, string, keyword, text, comment, function,
constant, attribute, variable, tag, property, number, module, type,
namespace, escape. Fourteen ts faces have no producer among them
(boolean, character, conditional, constructor, delimiter, exception,
field, float, include, label, macro, method, parameter, repeat); each
is a `defface!` that inherits the nearest coloured face, so a grammar a
user installs (Rust, Python) lands on a sensible colour. They stay. The
22 Emacs aliases with zero references (font-lock-*, mode-line-*,
minibuffer-prompt, vertical-border, variable-pitch, bold-italic) are
the compatibility layer the file announces, and Emacs is the reference;
deleting them is a ruling, not a cleanup. The four full palettes restate
the same faces because a palette is data, one colour per face per
theme; define-theme-from already covers a derived palette (tokyo-night).
Nothing in this item is deleted without a ruling. Ruled (2026-09-19):
keep the 22 Emacs aliases. Item 16 closes with no change.

**The Phase 2 gate, measured (2026-09-19, HEAD 74ee9cb2).** The six
layout files in one lane: 48 red. Alone: detail 3, layout-policy 9,
group-switch 11, window-config 1, autolayout 1, ibuffer-prompt 0; ten
names are red only in the combined lane (order pollution, listed in
KNOWN-FAILURES). Two names were missing from the ledger and are red at
4e14e5f2 too, before today's window work. Condition 1 does not hold yet.
Worktree attribution needs the worktree's OWN build: `cp -a _build/test
WT/_build/` (the priv links inside are relative), never a symlink to the
main tree's _build, or the run reads the main tree's init.scm against
the worktree's packages.

**Phase 3, the plan (2026-09-19).** Five steps, one commit each, in the
order of least risk and most unlocking. A step starts only when the
previous step's tests are green and its measurement is recorded before
and after. The numbers today: env.ex 546 lines, gc.ex 91, lane.ex 371,
session.ex 2,228, buffer.ex 3,511, editor.ex 3,580, editor_live.ex
4,319; `:compos_escaped_closures` is referenced from 19 files.

1. *One event stream and one sample* (section 8, item 15). Telemetry's
   ring is the stream; SysMon is the sample; perf.scm draws both.
   Profiler, live_dashboard and the hand-rolled SVG builders go.
   Elixir only. Tests: the telemetry rows read over the socket, M-x
   perf renders. Measure: nothing to measure; count the lines.
2. *Keymaps are Scheme data* (item 12). editor.ex keeps one lookup
   (`key-binding` over the buffer's map list); the 360 lines of ladder
   resolution and the ~30 handle_calls move to Scheme, where
   keymap-test.scm and keys-sweep-test.scm already read the maps as
   data. Measure: the per-key telemetry row before and after; a key
   must not cost more.
3. *One store, one read model, one wake path* (items 5-8, 15). The Loro
   log is the text and the author record; the catalog is derived at
   boot; the ETS row is the only read model for live and dormant
   buffers; `wake(name)` starts from the log and runs one
   `buffer-woken!` on the buffer's lane, always async. Tests: buffer,
   desktop restore, dormant buffers, provenance. Measure: boot time
   (3 s today) and the restore-loss history (six losses).
4. *One Display row model and one LiveView* (item 9, item 14 of section
   10). The "agent" render mode folds into "blocks"; Scheme composes the
   modeline and header blocks; static app.js and editor.css. Tests: the
   editor_live tests, blocks rendering, the per-command cost triage.
   Measure: the per-key render cost from the full-stack telemetry.
5. *The world collapse* (item 4, the Phase 4 decision). One serial
   Scheme process evaluates every policy; env.ex keeps ETS for the
   globals and a process map for frames, and the escape, promote, flush,
   roots, heir and retry machinery goes (~900 lines), because a closure
   never crosses a process. Two preconditions, both before the step
   starts: (a) the full hot-refresh the owner asked for (unload and load
   all Scheme), because C-g on a runaway eval in one world restarts the
   world, and a restart must rebuild every command and mode from source;
   (b) the benchmark (test/bench/ui_latency_bench.exs) run on the branch
   before and after. Acceptance: :ui p99 under the 1,500-chunk turn no
   worse than today's, and the worst keystroke wait behind a burst
   under one 25 ms frame. SchemeTask stays for pure reads until the
   benchmark says it can go.

Step 5 is REJECTED by ruling (2026-09-19). Asked what the world
collapse is, the owner answered "uh uh hahaha no no non nono". The lanes
stay: one process per lane, the escape, promote, flush, roots, heir and
retry machinery stays, and SchemeTask stays. Do not propose one serial
Scheme world again. Phase 3 ends with step 4.

**The lane machinery, tuned (2026-09-19).** The owner: "the lanes are
loadbearing and those 900 lines keep everything snappy ... if there is
some improvement you can make to the machinery i am all ears". Four
changes, none of which removes a lane:
- A frame GC sweep is a row in the telemetry ring (kind gc), so M-x
  telemetry and M-x perf show each pause.
- The GC mark reads frame edges with match specs and never copies a
  closure body out of ETS. Mark 38 ms to 21 ms median in a full editor
  boot (test/bench/gc_sweep_bench.exs), with the same live set.
- An eval that waits on a sweep polls every 1 ms, not 5.
- Compos.Core.Roots owns the GC root table (80 raw ETS calls in 19
  files before). eval-resolve! takes its entry in one step, and
  debounce-cancel! deletes only the generation it read.

**Tests live with their packages (2026-09-19).** The owner: "a
package's tests should live with it. like in emacs" and "we do not need
to test the packages when we test core. we can test them separately".
103 of the 141 Scheme test files move beside their packages as
scheme/packages/NAME-test.scm; 38 kernel files stay in priv/tests
(chats-list-test.scm stays too while the other session edits it). The
default mix test runs the kernel suite (scheme_suite_test.exs); the
package suite (package_suite_test.exs) runs with --include packages, and
M-x run-package-tests runs it in the editor. Hotload never evaluates a
test file on save. A test VM starts no workspace daemon
(workspace_daemons: false): two kernel tests each waited 30 s for one in
a worktree.

| run, in a worktree | before | after |
|---|---|---|
| one Scheme suite, 141 files | 249 s, 82 red | |
| kernel suite, 38 files | | 40 s, 18 red |
| package suite, 103 files | | 138 s |

Every red name in the two new runs is red in the old run or passes when
its file runs alone (order only).

**Step 4 (b), done in a worktree (2026-09-19).** The owner reversed the
drop ("chat would be a great proving ground for the elegance of our
construction"). A chat now renders through "blocks", the one block
renderer; the "agent" render mode is gone. Design and base numbers:
"Step 4b, design" below.

- Scheme composes the chat. `chat-view-sync!` (agent-transcript.scm)
  maps the transcript model to `'render-blocks`: an isolated list that
  follows its tail, the queued rows, the activity row, the prompt. The
  views hold byte ranges, not text. A memo keeps each block's view, so a
  pushed block builds one view. The sync runs per event batch
  (`agent-handle-events`), after each command that is not an input edit,
  and in the chat mode hook.
- Generic block kinds, any mode may use them: `range` with `format`,
  `details`/`summary`, `button`, `input` (the caret input, filled at
  render from the local that `'render-input` names), `isolate` (the
  `BlockList` component; each child drawn once as HTML) and `follow`
  (the `BlockFollow` hook; the place is `'follow-place`/`'follow-seq`).
- Deleted: `agent_leaf`, the `ag_block` clauses, `ag_input`,
  `AgentTranscript`, `AgentScroll`, the agent content of the handheld
  view, and three events (`agent_card`, `agent_answer`, `ag_stick`).
  The 83 `.ag-*` rules stay: they style the classes the chat tree names.
- The fold found a read-model defect. ETS copies a whole row to project
  one field, so a large local slowed every read of its buffer (a read of
  point cost 250 us with the tree in it). `BufferView` keeps a local
  over 16 KB in its own row, and a snapshot can hand out its stand-in;
  a list buffer gains the same speed (200 rows, C-n: 6.2 to 5.6 ms).

| chat, 300 blocks, typing (render_bench, p50 us) | 7742420e | after |
|---|---|---|
| key, end to end, alternate runs, one session | 23,729 / 23,582 | 24,942 / 25,206 |
| state / decorate (warm) | 55 / 0 | 43 / 1 |
| server handle_event per key | 1,535 | 1,581 |
| patch per key | 551 B | 703 B |
| Scheme tree: full / one pushed block / unchanged | none | 14,834 / 4,000 / 750 |

The server cost per key is the same; the patch carries the list
component's id again (152 B), and the test client pays about 1.3 ms
more for it. Screenshots of a chat (tool cards open and closed, a
permission, a queued row, the activity row, the input) at 7742420e and
after differ only in the header line. Lines: editor_live.ex 2,753 to
2,758, agent_transcript.ex 133 to 0, block_list.ex 48, editor.ex 3,100
to 3,091, buffer_view.ex 410 to 536, agent-transcript.scm +289.
Landing needs a daemon restart (the BufferView row shape changes).

What each step must not do: move a file another session holds (groups,
layouts, ibuffer are Phase 2), change a binding, or grow Elixir policy.
Step 5 needs the owner's go; steps 1-4 are mechanism and can start.

**Step 1, started (2026-09-19).** The live dashboard is gone: the
/dashboard route, Compos.Ui.Telemetry (the metrics supervisor and its
poller) and the three dependencies only it used (phoenix_live_dashboard,
telemetry_metrics, telemetry_poller). M-x perf is the sample; the
telemetry ring is the stream. Two pieces stay for a ruling, because
each is a working tool with tests: M-x profile (Profiler + profile.scm,
a per-command trace, not a duplicate of the telemetry rows) and the SVG
panels of perf.scm (perf-toggle-text already gives the plain table).
The lane slow-job warning stays beside its telemetry row: the freeze
triage of 2026-08 read the log, and the line is one Logger call.
Ruled (2026-09-19): "unless there is something wrong with them they are
all useful in their own right". M-x profile and the perf panels stay;
step 1 closes with the dashboard removal.

**Step 2, done in a worktree (2026-09-19 night): keymaps are Scheme
data.** editor.scm gains a keymaps section: `*keymaps*` (name ->
bindings and parent), per-buffer facts (minor maps, the map at point,
remaps), the global minor maps, the ladder, the resolution with prefix
keymaps, ESC as Meta, remaps, the read-only map, which-key rows, and
every function the 29 primitives used to be (same names, same
answers). Elixir keeps one call: KeyDispatch asks
`key-binding-dispatch` for a sequence; `key-context` answers the
frame's buffer and overriding map in one Editor call; the overriding
map, the pending prefix, last-keys and the capture stay frame state.
The which-key rows are no longer computed on every prefix key: the
client asks `which-key-rows` once its idle delay has passed. Editor
keeps four Scheme-backed readers for tests and RPC (lookup_key,
local_keys, buffer_local_map, local_bind_key). Gone from Elixir: the
keymap state, 28 handle_calls, the ladder, chain, resolve, flatten and
which-key helpers (about 750 lines), and the primitives in scheme_api.ex
and session.ex.

Cost, measured (test/bench/key_latency_bench.exs, p50 microseconds,
one key end to end through KeyDispatch.handle_key):

| key | HEAD | Scheme keymaps |
|---|---|---|
| C-f, a bound motion | 443 | 545 |
| C-x then C-g, a prefix pair | 526 | 702 |

The Scheme side of one lookup is 52 microseconds interpreted and a
table hit after the first press (a memo per buffer, overriding map,
sequence and keymap generation); the rest is the lane call. Three
caches carry it: the ladder per buffer, the prefix index per keymap
(the proper prefixes of every key and the keymap-valued bindings), and
the flattened ladder with its command-to-keys index, all dropped on any
keymap write. Without the last one M-x annotated a thousand commands
with key-for-command and blew the 1 GB Scheme heap.

Tests: keymap-test and keys-sweep show the same three and two reds as
HEAD; the eighteen editor_test names the port turned red in a full
file run all pass alone (the full file is order-polluted at HEAD too:
88 reds); the two which-key tests ask Scheme for their rows now.
Landing needs a daemon restart at once: a hot reload defines the tables
empty, and the bindings made at boot live in the old Elixir store.
Landed as 3c3d7972 (tree repaired in 22ba6cd2); the daemon restarted
23:17. One gap found after: the port defined `keymap--forget-buffer!`
and did not call it, so a killed buffer kept its map and facts.
59c7d3bd wires it into `buffer-kill!`; every minibuffer shares one
keymap key, so a minibuffer kill keeps the shared map. The ledger gains
list-group-and-sort-keys-run-the-declared-cycles, red before the port.

**The yes/no prompts, ruled (2026-09-19).** Asked whether y-or-n
(two callbacks) merges into y-or-n-p (one continuation), the owner
answered "we have been using ? no? i like that idiom". The 09-11
ruling applies: Emacs names, Scheme spelling. Both readers stay; the
`-p` names become `y-or-n?` and `yes-or-no?` (editor.scm, perf.scm,
google.scm, models.scm, docs/COMPLETION.md). No alias stays: a hot
reload leaves the old names bound in the live daemon until a restart.

**Step 3, design (2026-09-19): one store, one read model, one wake
path.** Items 5 to 8 and 15 of section 8. Written before the code, in
a worktree at 22ba6cd2.

*The store.* A persistent buffer has two files: `buffers/<id>.etf`, the
checkpoint, and `docs/<id>.loro`, the log. Today the checkpoint holds
the text and the log holds the text again. After this step the log is
the text: the checkpoint (version 2) carries the identity, the path,
the size, the point and mark, the flags, the locals, the folds, the
recording policy and the authorship spans, and no text. A buffer writes
the text into its checkpoint only when the log cannot answer for it: a
mode that opted out of recording (chat-mode), a mirror that failed, or
a log append that failed. A wake reads the log and builds the rope from
it; a dormant text read does the same. Every checkpoint written before
this step (version 1) still restores: the reader takes the text from
the file when the file has it, and the log reconciles against it as it
does today. A one-shot migration runs at boot, once per home: it
rewrites a version 1 checkpoint without its text only when the log's
text equals the checkpoint's text byte for byte, and it marks the
directory done. `catalog.etf` stays what it is today: the MRU list of
buffer names. Nothing else is derived from it.

*The read model.* One table, `:compos_buffer_view`, owned by
`Compos.Core.BufferView`, holds one row per known buffer: a live row,
which the buffer process publishes and which carries the rope, and a
dormant row, which carries the facts of the last checkpoint (id, path,
size, modified, read_only, point, mark, version), the locals under 1 KB
and the names of the rest. The boot scan of the checkpoint directory
writes the dormant rows. A buffer that stops demotes its own row: the
`DOWN` handler of `BufferView` rewrites a live row as a dormant row
from the row's own facts, and deletes a row whose buffer was killed
(the row carries `discard`). `BufferStore` keeps the MRU list, the boot
scan, the eviction sweep and the graveyard, and its own table goes.
Every reader in `Compos.Core.Buffer` reads the row first; a live buffer
with no row (the moment after `BufferView` restarts) asks its process;
a dormant buffer reaches its files only for the text and for a local
too big to index. `Buffer.point/1` tries one path.

*The wake door.* `Compos.Core.wake(name, opts)` is the one way a
dormant buffer comes back: it starts the process from the checkpoint
and the log, then queues one Scheme call, `restore-buffer-runtime!`
(which ends in `buffer-woken!`), on the buffer's lane, without waiting.
The queued job runs only when the buffer is still live. `restore:
false` starts the process and queues nothing, for a caller that
rebuilds the runtime itself or puts the buffer back to sleep at once.
`ensure_buffer/2` is the door for any name: live answers at once, known
wakes, unknown creates. The branch on the caller's process kind and the
`:compos_inline_runtime_restore` flag go. The seven paths become:

1. `create_buffer` on a known name: `wake`.
2. `ensure_buffer`: `wake`.
3. The `Editor` wrappers `set_window_buffer`, `window_set_buffer`,
   `preview_buffer`: no wrapper logic; the handler's `ensure_buffer`
   is the door.
4. `Editor.restore_tree`: the same handler door.
5. The `window-switch-buffer!` primitive: `wake(name, restore: false)`,
   then `switch-to-buffer-here!` in editor.scm runs
   `restore-buffer-runtime!` inline, as it does today. Scheme decides
   that a switch shows a whole buffer; Elixir does not guess it from
   the process.
6. `Buffer.via/1`, the wake by a write: `wake`.
7. `Desktop.restore_world`: wakes every buffer a saved tree names with
   `restore: false`, lays the trees, installs the globals, then queues
   the restores, in that order, because a mode setup reads the group
   records. `Desktop.restore_now/0`, the test API, waits on each
   buffer's lane after the call so a test sees the finished runtime.
   The Session-restart rebuild keeps its synchronous sweep: it is not a
   wake.
8. `rename_buffer` and `rename_file` on a dormant name: `wake(name,
   restore: false)`; `rename_buffer` queues the restore under the new
   name, `rename_file` sleeps the buffer again.

The eviction guard (`displayed`, `busy`, `agent`, `pinned`) becomes one
function, `Compos.Core.sleep_refusal/2`, read by `sleep_buffer/1` and
by the idle sweep.

*Behaviour that changes.* A wake from outside a lane (a test process,
an RPC caller) restored the runtime before it returned; now every wake
restores on the buffer's lane after it returns. Tests that read the
runtime right after a wake wait for it. A daemon older than this step
must not run over a home this step wrote: it reads a version 2
checkpoint as no checkpoint. Attribution still lives three times
(item 5); the authorship spans stay in the checkpoint until the log can
answer per-byte authorship.

*Measured before* (a test daemon in the worktree, 22ba6cd2):

| measure | before |
|---|---|
| boot of a test daemon (the migrations run: wall minus test time) | 10.7 s - 5.6 s = 5.1 s |
| test home after that run: `buffers/` | 2 files, 8 KB (catalog.etf 75 B) |
| test home after that run: `docs/` | 14 MB, kept across runs |
| store scan bench, 200 dormant buffers of 19 KB: checkpoint bytes | 4,034,473 |
| the same: log bytes | 3,968,981 |
| the same: boot scan of every checkpoint | 4 ms |
| the same: one wake with its text | 6 ms mean, 8 ms max |
| lines: buffer.ex, buffer_store.ex, buffer_view.ex, desktop.ex, core.ex | 3,511 / 414 / 328 / 557 / 338 |

The bench is `apps/compos_core/test/bench/store_scan_bench.exs`.

**Step 3, done in a worktree (2026-09-19).** Four code commits on
22ba6cd2: one sleep guard (`Compos.Core.sleep_refusal/2`); one wake door
(`Compos.Core.wake/2`, the rebuild queued on the buffer's lane, the
process-kind branch and `:compos_inline_runtime_restore` gone); the
dormant rows in `BufferView` (the `BufferStore` table and
`fact/local/locals/note` gone, `catalog.etf` is the MRU list only);
checkpoint version 2 (the log is the text; the migration in
`BufferStore.migrate/1`). Measured the same way:

| measure | before | after |
|---|---|---|
| boot proxy, two runs each, alternating | 5.1 s, 7.0 s | 5.2 s, 5.2 s |
| bench: checkpoint bytes, 200 buffers | 4,034,473 | 124,092 |
| bench: log bytes | 3,968,981 | 3,968,981 |
| bench: boot scan of every checkpoint | 4 ms | 4 ms |
| bench: one wake with its text | 6 ms mean, 8 max | 1 ms mean, 3 max |
| lines: buffer.ex / buffer_store.ex / buffer_view.ex / desktop.ex / core.ex | 3,511 / 414 / 328 / 557 / 338 | 3,508 / 424 / 410 / 594 / 424 |

The checkpoints shrink 32 times, because the text lives once. The line
count does not fall: the dormant row, the migration and the wake door
are new code, and the three read paths they replace were short.

Left undone, on purpose: the authorship spans and origins still ride in
the checkpoint beside the log (item 5), because the log does not yet
answer per-byte authorship; `desktop.etf` is unchanged. The restore-loss
history cannot be measured in a worktree; what changed for it is that a
desktop restore never waits on a rebuild. Landing needs a daemon
restart: the checkpoint format and the `BufferView` table shape change.

**Step 3, landed (2026-09-19, 7a123044..be8ed4e8).** The seven commits
landed on 5b84c082 as the same tree the worktree tested. A backup of
buffers/, docs/ and desktop.etf is in ~/.compos/step3-backup-20260919-011351. The owner restarted
the daemon at 01:14; the migration ran at 01:14:27. Of 686 checkpoints,
549 are now version 2 and 137 stay version 1 (chats, which do not
record, and one buffer whose log differs). A check against the backup
found every version 2 file equal to its old facts, with the old text
size, and every log byte for byte the same, except three buffers that
woke and appended to their logs. The 11 chats that saved again since
the restart keep their text in the checkpoint. Six version 2 buffers,
35 bytes to 1.6 MB, read back through the live daemon at their backup
size. The graveyard (buffers/dead/, 2138 files) is not migrated.

**Step 4, design (2026-09-19): one Display row model and one
LiveView.** Item 14 of Phase 3, items 3, 4, 5 and 10 of section 7.
Written before the code, in a worktree at 243fc29b. The design port is
the spec: every window must look the same after each sub-item. The five
sub-items land in the order of least risk, one commit each.

*(a) Markdown.Html owns the document.* Today editor_live.ex holds the
page around a Markdown body (`markdown_page`, the palette, the fonts),
the tree-sitter caller (`preview_doc_ts`, the line marks, the overlay
source) and the whole Earmark pipeline (`preview_doc`, the caret
heuristics, the fence labels, the LLM response tags, the embeds): about
1,000 lines. `Compos.Core.Markdown.Html` gains `document/3`: the page,
drawn by the tree-sitter renderer when the grammar is there. Earmark
stays, as the renderer of a home with no Markdown grammar, and moves
into core with the page. It cannot go: the grammar is not compiled in
(`native/compos_ts` has elixir, json, rust, html and diff), a fresh home
has none, and the chat prose and every preview then draw through
Earmark. A screenshot of such a home at 243fc29b shows the tables and
the emphasis that a plain fallback would lose. The LiveView keeps the
iframe and the cache key; the transcript's `prose_html` calls core.

*(b) The "agent" render mode folds into "blocks".* Scheme composes the
transcript as a block tree; editor.ex loses `agent_leaf`, editor_live.ex
the `ag_block` clauses and `ag_input`, and `AgentTranscript` becomes the
isolation component of any block list. What it needs that the block
renderer lacks: a raw HTML block (the prose), a disclosure block (the
tool card), a caret block (the input), and the reference-equal block
list the chat-input-perf fix depends on. The Scheme half is in
chat-mode.scm and agent-fleet.scm, which another session edits now.

*(c) Scheme composes the mode line and the header blocks.* The window
mode line becomes a block list that modeline.scm builds with the
dashboard line (`modeline-blocks`), and the view fills Emacs's
`%`-constructs in it (`%l`, `%c`, `%p`, `%I`) at render, so a caret
motion costs no Scheme. The echo area's key hints and the other chords
written in editor_live.ex (`@header_keys`, the workspace bar, the "more"
tab, the transient default legend) come from Scheme variables that the
frame carries. editor.ex keeps the walk and loses `modeline_group`,
whose value no client reads.

*(d) One Display row model in core.* `viewport_lines`, `build_static`,
`display_spans` and `render_pass` move from the LiveView to a core
`Display` module that answers rows per window, memoized by buffer
version, for the LiveView, the handheld client and /raw. The
whole-buffer `build_static` goes: a window builds the rows it ships.

*(e) Static app.js and editor.css.* layouts.ex holds 2,926 lines of
script and 1,647 of stylesheet in the root layout. They move byte for
byte to `apps/compos_ui/priv/static/app.js` and `editor.css`, served by
the existing `Plug.Static` with the boot id in the query. Hotload
watches that directory and bumps the boot id on a save, as a swap of
the layout module does today.

What stays: the Window and AgentTranscript components (the
zero-work-on-clean-tree and chat-input-perf rulings), the per-window
decorate cache, the iframe preview, the handheld LiveView (a second
LiveView is item 2 of section 7 and a Phase 2 layout question).

*Measured before* (243fc29b, `apps/compos_ui/test/bench/render_bench.exs`,
p50 microseconds, 60 keys; state = `Editor.render_state`, decorate = the
warm view pass, cold = the view pass with an empty cache, key = one key
through the LiveView end to end in the test client):

| window | state | decorate | cold | key | page |
|---|---|---|---|---|---|
| file, 3k lines, C-f / C-b | 47 | 8 | 512 | 10,604 | 142,817 B |
| file, 3k lines, typing | 82 | 9 | 532 | 11,713 | 142,826 B |
| chat, 300 blocks, typing | 87 | 0 | 138,776 | 26,193 | 240,859 B |
| blocks, 200 rows, C-n / C-p | 71 | 34 | 236 | 6,280 | 104,830 B |
| markdown page, 400 lines, C-f | 15 | 26 | 72,127 | 4,830 | 181,371 B |

| lines | 243fc29b |
|---|---|
| editor_live.ex | 4,335 |
| agent_transcript.ex | 133 |
| editor.ex render walk + modeline_group/pin + agent_leaf | 212 + 51 + 45 |
| layouts.ex (script / stylesheet in it) | 4,873 (2,926 / 1,647) |
| .ag-* and .agent-view CSS rules (layouts.ex / mobile_layouts.ex) | 85 / 51 |
| Markdown: markdown.ex, markdown/html.ex, the Earmark path in editor_live.ex, oembed.ex | 181, 822, ~570, 188 |

**Step 4, done in a worktree (2026-09-19).** Six code commits on
243fc29b, one per sub-item, plus the script ejection the owner ruled
("all js in its own files"; the doom and spreadsheet scripts "should
not be in core").

- *(a) done.* `Markdown.Html.document/5` draws the preview page; the
  page, the palette and the transcript prose (`Html.prose/1`) are core.
  Earmark stays as `Markdown.Classic`: the Markdown grammar is not
  compiled in, so a home without it draws every preview and chat
  paragraph through Earmark (a screenshot of such a home shows the
  tables and emphasis a plain fallback would lose).
- *(e) done.* app.js and editor.css in priv/static, loaded with the boot
  id; Hotload's `:hotload_page_assets` watch bumps the boot id on a
  save. The files keep the parsed script byte for byte (same syntax
  tree). The handheld layout (mobile.js, mobile.css) and the app
  origin's bridge (app-bridge.js) followed.
- *(c) done.* The window mode line is the `mode-line-format` custom
  (appearance.scm), a list of constructs; the view fills `%I %l %c %p`.
  The echo hints (`echo-key-hints`), the workspace bar help and the
  more-tab title reach every frame through `frame-chrome-set!`; the
  transient default legend is Scheme data. `modeline_group` is gone
  from editor.ex. The frame header's wordmark and tabs markup stay in
  the view.
- *(d) done in part.* `Compos.Core.Display.window/3` answers a text
  window's rows, memoized by version in an entry the caller keeps; the
  LiveView and the handheld view (through `decorate_tree`) draw it. A
  peek card builds at most 2,000 rows. Left: the memo is still one per
  client process, not one per window in core; /raw serves text and does
  not read rows.
- *(b) left.* The fold needs the Scheme half in chat-mode.scm and
  agent-fleet.scm, which another session edits now, and four block
  kinds the generic renderer lacks (raw HTML prose, a disclosure card,
  a caret input, the reference-equal list the chat-input-perf fix
  needs). It is a design of its own, not a day's move.
- *Scripts.* The spreadsheet grid script is
  scheme/packages/spreadsheet/spreadsheet.js, served from the buffer's
  `app-directory`; the doom page script is scheme/packages/doom/doom.js,
  copied beside doom.html. The app server's three spreadsheet routes
  are one bridge, `_compos/app`, that runs the keyed `app-request` hook.
  No `<script>` with a body is left in apps/ or scheme/ outside tests.

Measured the same way as the design (render_bench, p50 microseconds, the
second of two alternating runs):

| window | state before / after | cold before / after | key before / after |
|---|---|---|---|
| file, C-f / C-b | 46 / 47 | 451 / 453 | 10,244 / 10,337 |
| file, typing | 88 / 81 | 456 / 514 | 11,187 / 11,077 |
| chat, 300 blocks | 64 / 56 | 138,487 / 135,541 | 23,648 / 23,630 |
| blocks, 200 rows | 73 / 89 | 236 / 234 | 6,152 / 6,308 |
| markdown page | 15 / 16 | 69,946 / 69,147 | 4,704 / 4,744 |

The per-key cost does not change; the render path moved, it did not
grow. The root page is 247,222 bytes before and 1,579 after, with the
script and the stylesheet cached by the browser; the handheld root is
38,163 and 1,285. Lines: editor_live.ex 4,335 to 2,753, layouts.ex
4,873 to 50, mobile_layouts.ex 645 to 55, editor.ex 3,115 to 3,100;
new in core: display.ex 557, markdown/classic.ex 886, markdown/html.ex
822 to 1,138. Screenshots of a file, a chat, ibuffer, a Markdown page
and the handheld view, at 243fc29b and after, differ only in the clock
and memory figures of the header line and the ages in ibuffer.

Landing needs a daemon restart: the Endpoint's static list and the
Hotload roots are read at start, and the root layout now links files
that a running page does not have.

**Step 4b, design (2026-09-19): the chat renders through "blocks".**
Written before the code, in a worktree at 7742420e. The design port is
the spec: a chat must look the same after each commit.

*Scheme composes the chat.* agent-transcript.scm gains
`chat-view-sync!`. It maps `'agent-blocks`, the open cards, the
verbosity, the queue and the activity word to a block tree in
`'render-blocks`. The tree has the same elements and classes that
`AgentTranscript` draws today, so the stylesheet does not change. A
memo keeps the view of each transcript block, so a new block costs one
new view and not a new tree. The sync runs at the end of
`agent-handle-event`, after every command in a chat, and in the chat
mode hook. A chat's render mode is "blocks"; mode setup changes a
saved "agent" to "blocks".

*Four generic block kinds.* The block renderer gains what the chat
needs, and any mode can use them:

- `range (S E)` with `format`: the block draws its own buffer text
  from S to E. "text" trims it, "markdown" draws it as prose HTML
  (core `Markdown.Html.prose`), "mcp-result" and "mcp-result-line"
  unwrap a tool result. The tree holds offsets, not text, so a local
  write does not copy the transcript.
- `details` and `summary`: a disclosure. `open` is Scheme's; a summary
  with a click is controlled, and the browser does not toggle it.
- `input #t`: the caret input. The view fills it at render from the
  window's text and point, from the byte in the local that
  `'render-input` names. A key does not run Scheme to redraw it.
- `isolate #t`: the children draw inside the `BlockList`
  LiveComponent. The decorate cache keeps each child's view by its
  plist and its range bytes, so an unchanged child is the same term,
  and a key that changes only the input diffs the list to a skip.
  `follow #t` adds the tail-follow hook, and the reader's place is the
  generic `'follow-place` and `'follow-seq` locals.

*Deleted after the switch:* `agent_leaf` in editor.ex, the `ag_block`
clauses, `ag_input`, `AgentTranscript`, the `AgentScroll` hook, the
agent content of the handheld view, and the `.ag-*` rules that no
Scheme class names. The handheld view draws a blocks window with the
same renderer.

*Measured before* (7742420e, render_bench, p50 microseconds, 60 keys):

| window | state | decorate | cold | key | page |
|---|---|---|---|---|---|
| chat, 300 blocks, typing | 61 | 0 | 148,387 | 25,105 | 240,859 B |

| lines | 7742420e |
|---|---|
| editor_live.ex | 2,753 |
| agent_transcript.ex | 133 |
| editor.ex `agent_leaf` | 45 |
| app.js `AgentScroll` | 186 |
| `.ag-*` rules, editor.css / mobile.css | 84 / 50 |

**Phase 2, the three designs its condition 3 asks for (2026-09-19,
proposed; each is one page and waits for the owner's agreement).**

*4.2 The window leaf: `buffer history top side owner`.* Today a leaf is
the 7-tuple `{:leaf, buffer, top, point, manual, ctop, history}` (the
point is read and discarded), and a popup is a window whose buffer
carries a CSS class string that editor.ex parses (popup--class? in
Scheme, the class parse in Elixir: four ways to say "this window
floats"). The leaf gains two fields. `side` is `#f` for a work pane or
one of `popup`, `dock`, `minibuffer`: the frame has at most one window
per side, `layout-visible-window?` reads `side`, and the class string
becomes a face the renderer derives from `side`. `owner` is `#f` or the
id of the window that asked for this one: peek-window,
listing-preview-target, the detail window, the collect window and
group-preview each keep that pointer in their own frame-local today;
with `owner` on the leaf, `quit-window` in an owned window returns to
its owner, a kill of the owner closes its owned windows, and
window-tree-rename/sanitize walk one field. `window-tree` prints
`(:leaf buffer top manual ctop history side owner)`; a saved tree from
before reads with `side #f owner #f`, so no desktop migration (a
migration in migrations.scm is the fallback if a reader needs one).
Elixir: build_tree gains the two fields and `window-side`/`window-owner`
primitives; nothing else. Tests: window-config, detail, peek, popup
tests read `side` and `owner` as data. Measure: the window-rearrange
timings of 4a before and after.

**Amended by the owner (2026-09-19): "we are not doing side windows.
popups will be the floating overlay. you can get rid of everything
else. the ux philosophy is of minimal movement. efficient everything."**
So the leaf gains `owner` only. There is no `side`: the popup is not a
window kind, it is the one floating overlay over the panes, outside
the window tree, and dock, side and hidden windows go with the class
string. A window is a pane of work or it is owned by one; the popup
floats. Every design below reads with that in mind: minimal movement
of windows, focus and point; nothing that costs the user a step.

*4.6 The `display-preview` action.* One action in the display chain,
`(display-preview NAME OWNER)`: show NAME in the window OWNER owns (make
it with `owner` set when there is none), never bump the buffer MRU,
never move focus, never enter winner's ring, and remember nothing
beyond the leaf. Peek (`peek-file!`, `peek-buffer!`), listing-preview
(`listing-preview!`, `-schedule!`, `-dismiss!` in ibuffer.scm), the
switcher's `switch-preview!`, collect, the group preview and detail's
`display-buffer-detail!` become callers that pick OWNER and NAME; the
rules they carry today (the 1 MB peek cap, the debounce, the projector
for a text preview, "the other window, never a popup") stay as their
own one-line policies in front of the action. Dismissal is one verb:
`quit-window` in the owned window, or the owner's own dismiss, deletes
the owned leaf. Tests: display-buffer-test, peek-test, detail-test and
the ibuffer preview tests assert the leaf's `owner` and that MRU and
winner did not change. Measure: the listing-preview debounce budget
(120 ms) and the per-key cost rows.

*5.10 The config record.* One record
`(name connector cmd model effort servers stance)` where `servers` is
a list of server NAMES. The MCP registry (`*mcp-registry*`, resolved in
one place by `mcp-resolve-spec`) is the only server table; a bundle
names its servers instead of carrying a copy of each spec, the hub
lists the table, the bundle picker composes from it, setup's program
registry becomes rows of the same table with a `program` key, and the
workspace LLM defaults are one bundle named `workspace`. `compos`, the
editor's own MCP server, is a row like any other with `builtin #t`, so
the five special cases become one predicate. The bundle accessors in
chat-mode.scm (`llm-bundle-get/put/normalize`, the key pool) stay as
the record's API and move to a `config.scm` package with the picker.
Persisted shape: bundles keep their plist; a `servers` value that holds
specs (an old desktop) migrates once to names through migrations.scm.
Tests: transient-test and llm-setup-test (the bundle picker), a new
config-test for the record and the migration, mcp-hub-test for the one
table. Measure: line counts of llm-config.scm, setup.scm, mcp-hub.scm
before and after (951, 713, 419 today).

**Phase 2, the window design: three kinds of saved state and one preview
verb (2026-09-19, proposed; waits for the owner's answers below).**

*What is there now (measured).* Seventeen mechanisms save a frame's
arrangement or a window's buffer and put it back later (about 770
lines), and ten mechanisms show a buffer for a while without keeping it
(about 700 lines). They are listed with file:line in the inventory of
2026-09-19. The same moment often writes the same thing more than once:
a group switch writes the tree to winner, to the group record, and (from
the switcher) to a closure; an entered popup keeps three records and
also pushes winner; the invoking window of a list prompt is put back by
three separate Scheme copies (switch.scm twice, ibuffer.scm once), while
the Elixir leaf already holds the same fact as `preview_origin`.

*The design.* A saved arrangement has one of three lifetimes, and each
lifetime gets one place to live.

1. **The window: `restore` on the leaf.** A window remembers what to do
   when its current display ends: `'delete` (the display made this
   window) or the buffer and point it covered. This is Emacs
   `quit-restore` as leaf data. It replaces the global
   `*window-quit-restore*`, the three home-window copies (switch-home,
   the bare-prompt closure, ibuffer-prompt-home), the definition-peek
   restore by hand, and the Elixir `preview_origin` field, which it
   generalises. `quit-window` reads it; a kill of the shown buffer reads
   it. The 4.2 `owner` field (the window that asked for this one) sits
   beside it on the same leaf.

2. **The frame: one return stack.** An arrangement that a mode or a
   prompt puts over the frame and takes away again is one entry on a
   frame-local stack: `(arrangement-push! REASON)` answers a token,
   `(arrangement-pop! TOKEN)` puts the tree, the group, the layout
   target and the focus back, and `(arrangement-drop! TOKEN)` keeps
   what is on screen now. The ibuffer and chat-list transient frames,
   the entered popup, the overview, the group switcher's look, the
   window-layout prompt and the movie return become callers. The focus
   token around a retile stays as it is: it saves focus only, for the
   length of one call.

3. **The group: its saved layout.** A group's own arrangement stays on
   the group record, because it outlives the frame and the session. It
   is written in one place: when the frame leaves the group. The
   switcher and the foreign-pane save points go, because a switch now
   enters the buffer's group (the ruling of 2026-09-19) and the
   switcher's look is a stack entry.

Winner is the history of what the user did, not a fourth store: it
records the tree once per completed window command, from the one
window-state change path, instead of the eleven `winner-push!` calls
today. A stack entry, a preview and a layout reflow do not enter it.

*One preview verb.* `(preview-show BUF WHERE)` and `(preview-end KEEP)`,
one slot per frame (the peek ruling). WHERE is `here` (the invoking
window, restored from its leaf), `other` (the owned window of 4.6),
`float` (the popup card, the one floating overlay) or `frame` (a
whole-frame look, a stack entry). A preview never bumps the MRU, never
moves focus and never enters winner. `KEEP` true commits what is shown
(RET twice keeps, the peek ruling); false puts back what was there.
Peek, listing-preview, the switcher preview, the candidate previews
(switch, project ripgrep, code, lsp, chat-list), collect, the group
preview, the layout preview, definition-peek and the list-mode
`preview` hook become callers that choose BUF and WHERE. Each keeps its
own one-line policy in front of the verb (the 1 MB peek cap, the
debounce, the text copy for a listing). The private state goes:
`peek-window`, `peek-shown`, the `listing-preview-*` locals,
`*collect-window*`, `*peek*`.

*What goes.* Hidden windows (layouts.scm, `*hidden-windows*`), by the
amendment "you can get rid of everything else". The detail window stays
a display, not a preview: it opens an owned work window that the user
keeps.

*Order of work, one commit each, lines counted after each.*
(a) `restore` on the leaf; the three home copies, the global
quit-restore and `preview_origin` go. (b) The preview slot and verb; the
callers move one at a time. (c) The return stack; the six frame-level
callers move. (d) Winner from one path; the scattered pushes go.
(e) Hidden windows go; the group layout is written in one place.
Expected: the 1,470 lines become about 600. Tests per step:
window-config, peek, detail, display-buffer, ibuffer-prompt,
group-switch, layout-policy, layouts, winner and the popup tests, which
assert the leaf data, that MRU and winner did not change under a
preview, and what each dismissal restores. Measure the window
rearrange time before and after each step (a rearrange that takes
seconds is a first-class defect).

*Ruled by the owner (2026-09-19).*
1. A list row's preview is the floating card (`float`), as ibuffer and
   ichat do now. This replaces the 2026-09-07 ruling "previews always in
   the other window, never a popup" for list rows; peek of a file or a
   definition keeps `other`.
2. Winner records every completed window command automatically, from
   the one window-state change path (Emacs winner-mode).
3. Hidden windows go.

**Phase 2, landed in a worktree (2026-09-19).** Steps (a) to (e) of
the window design are six commits on daef54c5. Each step ran window-config,
peek, peek-md, detail, display-buffer, ibuffer, ibuffer-prompt,
group-switch, layout-policy, layouts, winner, popup-move, overview,
window-history, switcher-sleep and chats-list, and the Elixir listing_*,
dismiss, window_heal, desktop_restore, frames and editor tests. Every red
is red at daef54c5 too, or is a timing leak between lanes (below).

| Step | Commit | Source lines (+/-, net) |
|---|---|---|
| (a) `restore` and `owner` on the leaf | 36a7aae2 | +262 -118, +144 |
| (b) `preview-show` / `preview-end` | cee3b6a1 | +210 -223, -13 |
| (c) the frame return stack | b35f5d39 | +95 -132, -37 |
| (d) winner from one path | ae982cab | +61 -60, +1 |
| (e) hidden windows go, one layout write | f07b54db | +33 -177, -144 |
| A9 cleanup | 80d00662 | -7 |

Net: -56 source lines (Scheme -218, Elixir +162), not the ~870 the design
expected. The Elixir leaf API (restore, owner, the preview record) is
new code. What the steps did not shrink: the listing card's copy
machinery (ibuffer.scm), the group switcher's prompt body, the popup's
own stack of buffers, and peek-recent. Those are the next cuts.

Window rearrange time, p50 over 30 runs in the test VM
(apps/compos_core/test/bench/window_rearrange_bench.exs), daef54c5 then
HEAD: group switch 5.5 / 5.8 ms, peek show and dismiss 40.2 / 39.3 ms
(the file visit is the cost), listing preview 6.5 / 6.4 ms, layout
choice 10.7 / 12.8 ms (the choice is now a kept frame look: one stack
entry pushed and dropped), winner undo 1.4 / 1.6 ms. No step made a
rearrangement cost more than milliseconds.

What changed for the user:
- A visit clears a display's quit record, as in Emacs. quit-window
  after a switch in that window walks the window's history.
- A popup close does not put back the point the return window had at
  open; the window keeps the buffer's own point.
- The switcher, the ibuffer and chat-list tables, the overview and the
  movie give the frame back through one stack; a pop also restores the
  layout target.
- Winner records the arrangement a key command changed, once, from the
  pre- and post-command steps. An eval or an agent that changes the
  windows between commands is where the next command starts, not an
  entry. The configuration hook runs in another Scheme lane, so winner
  writes nothing from it.
- A group's saved layout is written on each completed window change
  (owner's ruling, 2026-09-19: "group layouts should be saved on each
  change"), by group-layout-record! from winner's pre- and post-command
  steps. A change that enters another group is an arrival and writes
  nothing, so a restore is never recorded as a change. A leave flushes
  the change the same command made, and the adoption of a screen by a
  move (no window changes) writes once. The switcher no longer
  snapshots on open, and a foreign display no longer checkpoints.
- mode-consolidate drops the other buffers from the destination's
  history; nothing hides them in an invisible window.

Found on the way: the configuration hook runs in another lane and reads
frame locals that the test lane has not flushed, so winner-test,
layout-policy-test and the group-switch look tests are timing-dependent
at daef54c5 as well. group-switch's buffer-prompt test fails at
daef54c5 too once editor_test has left buffers in the test home.

Found on the way, and fixed (b5271dc7): a Session restart after a crash
failed with "init.scm failed to load: unbound variable: capf-auto-watch!".
agent-session.scm (under agent.scm) runs the chat mode hook on the chats
already open, and the hook calls capf-auto-watch!, which completion.scm
defined later in init.scm. A cold boot has no chat open at that point;
a restart does. init.scm now loads completion.scm before the apps. The
failure is present at 71f02c62 and aff8bcc8.

Landing needs a daemon restart: the window-tree leaf tuple grew from 7
to 9 fields, and a hot swap of editor.ex would meet trees the old code
built. Desktop files keep the 7-tuple and read unchanged.

*5.1 M-o.* Decided and shipped as the chat merge above: llm-mode stays
the lane, a hidden chat per document, `C-u M-o` picks the target.

**The layout reds, bisected (2026-09-19 night).** group-switch-test.scm
in a worktree with its own build and the current harness: 2 red at
66d2ea54 (the two switcher-heading tests), 5 at 8f859bba (an agent
commit of 2026-09-11 that changed the `(category foreign)` rule from
`popup` to `(reuse-window use-some-window pop-up-window)` and rewrote
the switch-to-buffer! doc to "takes another window"), 6 at f6ad9f51
(the group MRU cache), 9 at 0a3bfa57 (SPC for marking), 11 at HEAD
(make-frame! deleted in 7c37b1b2 as "no caller outside a test";
restored now, two tests green again). The file holds two generations
of the foreign policy: `confirm-floats-a-buffer-of-another-group...`
and `switching-to-an-ungrouped-buffer-floats-it...` want the popup and
"the frame stays in its group"; `a-foreign-buffer-is-a-display-of-
category-foreign` (newer) wants the window chain and "nothing floats".
Putting the popup rule back turns the newer test red and leaves the
older two red on the group assertion, so neither generation passes
today. RULING NEEDED: which foreign policy stands (the popup, per the
sealed-groups ruling; or the other window, per the 2026-09-11 commit
and the open-in-the-other-window ruling), and in both cases the frame
must keep its group when a foreign buffer shows, which no code does
now. The remaining six names (headings, MRU cache, SPC marking) date
from the other session's switcher commits and wait with it.

The other two files, bisected the same way: layout-policy-test.scm is
8 red at 66d2ea54 (2026-09-11, before the foreign flip, the day of its
own last commit 05109325), so its target-layout tests were committed
red as a spec of work in progress; detail-test.scm is 2 red at its own
last commit b5123dce (2026-09-15: the detail window after a swap, and
the kept detail's rename), and its third name passes alone (verified in
a scratch file) and is red only behind those two. Nothing in the three
files went red under the simplification except make-frame!. The Phase 2
gate is therefore the other session's unfinished switcher and
target-layout work, and making those tests pass is their design, not a
cleanup; it waits for them or for a ruling that those specs stand.

Tried and reverted (2026-09-19 night): the 09-11 intent, "the frame
keeps its group while any pane still belongs to it", as a sticky case
in group-current-choice. It turns
`a-switch-to-a-foreign-buffer-takes-a-window-and-the-frame-stays-in-its-group`
green and turns three older tests red that assert the derived rule:
`current-group-is-derived-from-every-visible-work-buffer`,
`a-foreign-pane-saves-the-layout-it-leaves-and-the-switch-back-restores-it`,
`group-switch-preserves-mru-in-a-mixed-frame`. The 2026-08-30 sealed
groups ruling ("a foreign pane takes the frame out of the group and
saves the layout") and the 2026-09-11 test ("takes a window; the group
holds") cannot both stand. The ruling to give: which one, and then the
losing tests are deleted, not fixed.

**Ruled (2026-09-19, the owner): "foreign buffer switches the group";
"when chosen, it can still pop up in ibuffer or ichat".** A switch to a
buffer of another group enters that group (switch-to-buffer! follows
the buffer home through switch-to-buffer-in-group!, as a chat already
did); a switch to an ungrouped buffer takes the window and the frame
leaves its group by the derived rule; a list's chosen row may still
float. The three tests of the losing generations are deleted and two
state the ruling (group-switch-test.scm). docs/groups.md says it. After
the ruling: group-switch 5 red (the switcher headings and MRU work of
the other session), layout-policy 8, detail 3, ibuffer-prompt 6, all in
the ledger; groups, group-membership, switcher-sleep, window-config
green or ledgered.

**Phase 2 gate, closed by ruling (2026-09-19).** The owner ruled: "the
current implementation is correct. make the tests pass." The code at
3b9a263f is the spec for the four files that held the gate. Red before,
each file alone: group-switch 5, layout-policy 8, detail 3,
ibuffer-prompt 6 (22). Red after: 0 in each file alone, and 0 with the
four files in one lane. No test is deleted. Fourteen tests now state
what the code does: ibuffer-prompt is the plain minibuffer list, and
the table is ibuffer-prompt-pretty in a dock; a section wears its
group's name; a sanitized restore keeps the hidden pane in the
snapshot; a switch to a visible member selects its window; detail-keep
keeps a name the buffer owns; a foreign display takes a pane and the
frame leaves its group. Eight tests were red for a setup reason. The
layout-policy fixture reused the group of the last journey, because
group-create-and-enter! refuses a name that exists. The editor runs
window-configuration-changed! from a detached task (editor.ex,
config_hook), and its target reflow raced the test steps; the same file
went red on different names from run to run. The layout journeys and
the detail target test hold layout-target-on-change! out of the hook
while they run. The race is real outside the tests too: a reflow can
arrive after the command that caused it. That is a finding for Phase 2,
not a test fix.

**Item 15, ruled (2026-09-19):** "the keys i want - text-scale-decrease,
undo on C-/, keep the C-x b. in fact you can delete the other
implementation. this is settled. C-t is telemetry." Done: the shadowed
`C-_ undo` and `C-t transpose-chars` lines are gone (undo is C-/,
transpose-chars has no key); switch-to-buffer-prompt and the seven
helpers only it used are deleted, chrome's C-x b chord and the
handheld's tab hold run ibuffer-prompt, the group-switch tests drive
ibuffer-prompt. Two features died with the old prompt and are not in
ibuffer-prompt: members of the frame's group listed before other
buffers, and C-RET on a typed name founding a group; their two tests
are deleted. goto-address-at-point leaves C-c RET (the chat companion's)
for M-., through goto-thing-at-point: an address at point is followed,
else code-goto-definition; lsp.scm no longer binds M-. itself (a mode
map may still bind M-. to definition-peek and wins in its buffer).

**Winner and the layout engine (2026-09-19).** winner-undo restored the
tree and the configuration hook tiled it back to the target: the target
compares the visible pane count to the count it noted at the last tile,
and a columns tile fills a third pane from the buffer list. A restore
now runs `winner--settle!`: it notes the target's slots from the restored
windows and runs `winner-restore-hook`, where layouts.scm makes the
restored panes autolayout's current panes. The target and autolayout-mode
stay set. Tests: winner-test.scm. The layout prompt confirms in one step
and the preview is debounced (120 ms).

**Phase 2 entry conditions (2026-09-19).** Phase 2 rewrites behaviour in
groups.scm, layouts.scm, ibuffer.scm, editor.ex and the chat lane. It
starts when all four hold, and not before:

1. The layout tests are green at HEAD: layout-policy, group-switch,
   autolayout, window-config, detail and the ibuffer prompt tests (26
   names in docs/KNOWN-FAILURES.md, red today from the listing-preview
   work in the other session). A redesign with a red baseline cannot
   tell its own breakage from the inherited one.
2. The other session has landed its groups, layouts and ibuffer work;
   git status shows none of those files dirty for a day.
3. A one-page design for each item, agreed first: the window leaf with
   `side` and `owner` (4.2), the `display-preview` action (4.6), the
   config record (5.10), and what M-o does once llm-mode is gone (5.1).
4. The measurements in 4a repeated on the design branch before and
   after, since window rearrangement time is first class.

Order inside Phase 2 once open: the config record (5.10, tests in
transient-test and llm-setup-test), permit? (5.9), the display-preview
action (4.6, tests in display-buffer, peek and detail), then the chat
merge (5.1, 5.11, 5.12) last because every chat test that could guard
it is red on the fake transport today.

**Next three steps, in order.**

1. `load-path`: the defvar in editor.scm, `load` searching it in Scheme over
   the one-path builtin, Hotload and the write roots reading it,
   `load-bundled-package` deleted. One commit; tests in
   `priv/tests/load-path-test.scm`. No file moves, so it does not collide
   with other sessions.
2. The move: `git mv apps/compos_core/priv/packages scheme/packages` once the
   tree has no uncommitted package edits, plus the release step. One
   commit, no code change.
3. In parallel with either: the Phase 0 deletions that touch nothing anyone
   is editing. The 52 unreferenced primitives, SchemeActor, the 43 test
   wrappers, the `plist-get` builtin fix and its 25 wrappers, the secrets
   seam.

**Phase 0, mechanical and safe.**
1. Delete: 52 unreferenced prims, 25 dual spellings, SchemeActor, the 43
   test wrappers, the Elixir half of the 40 double-covered features, demo-app
   tests, dead commands and functions from sections 3.8 and 5.14, root cruft,
   stale worktrees, 44 docs.
2. Move every package to `scheme/packages/` at the project root; priv keeps
   the kernel. Drop the 15 personal apps, calendar, and org.scm from
   init.scm. homepage_live.ex becomes static HTML in the repo.
3. Secrets seam: `secret-provider` custom in keys.scm; delete
   `key--from-doppler`, the `*-doppler-project` customs in sentry and
   google, doppler.scm; the provider is one lambda in user config.
4. Builtins: plist-get returns #f on non-list; alist-put!/get/delete;
   string-replace, html-escape, take, string-clip, first-line, basename;
   buffer-set-text!; time-label. Delete the ~110 private copies.
5. One test support module: eval!, press, wait_until, one FakeTransport.

**Phase 1, registries.**
6. One catalog; public! = catalog-register!; one `prim` macro with docs;
   each connector exports its primitives; drop domain!/category!/
   namespace!/catalog-meta!, keep one 'effects tag.
7. One define-mode with keyword args and mode-get; one defvar with 'persist.
8. Keyed hooks replace the on-X! wrappers, keyed registries, re-set! seams
   and the 79 boundp guards. Declared `requires` order init.scm.
9. Move whole sections out of editor.scm: lists, chat/LLM, dashboard,
   layouts, peek, popper, isearch, remote, terminal, collect, palette,
   visual lines. editor.scm lands at ~4k.

**Phase 2, domains.**
10. Windows: window-configuration value; leaf side/owner; one
    display-preview action; one MRU; one arrange!; list-mode 'surface;
    fold *frame-locals* into the frame; split chat naming out of groups.scm.
11. Agent: config record; permit?; eval + ask + apropos-as-function; Backend
    base + JsonRpc over Endpoint.Conn; delete codex_app_server if codex-acp
    works; one chat.scm with one transcript module; delete llm-mode; trim
    sentry, worktrees, jj, prompts, title/summary.

**Phase 3, runtime.**
12. Loro log is the text and the author record; catalog derived; one read
    model; one wake path; code_change instead of per-message upgrade.
13. Minibuffer is a buffer with a mode; keymaps are Scheme data; motion and
    kill policy in Scheme; landing policy out of the Editor GenServer.
14. One Display row model in core; one LiveView; static app.js/editor.css;
    Markdown.Html owns the document; "agent" render mode folds into
    "blocks"; Scheme composes modeline and header blocks.
15. One event stream + one sample; drop Profiler, live_dashboard, ChatPerf,
    the SVG builders.

**Phase 4, decision.** Benchmark `:ui` latency under an agent turn with one
serial Scheme world. If it holds, collapse env.ex, gc, roots, flush, the
heir dance and the retry loops.

**Duplicate cuts (2026-09-19, worktree on 121de726).** Five items, one
commit each. Net lines are source files only, tests excluded.

| Item | Commit | Net |
|---|---|---|
| 1. conn-list, conn-detail, conn-log, on-event! replace 15 prims (7.11) | 4dd0801e | -43 |
| 2. MCP stdio, the socket server and the peer use Compos.Core.JsonRpc | 71e98166 | -11 |
| 3. The Google OAuth redirect lands on a WebServer server (7.7) | 19cff474 | -2 |
| 4. save-done!: one epilogue for six save paths (3.9) | 00565244 | -3 |
| 5. The peek-recent command goes | 9afebe07 | -12 |

Net: -71 source lines. Item 1 keeps mcp-connections and lsp-connections
as Scheme functions over conn-rows, because five packages read their row
shape. fs-on-change! and block-on-click! stay single-slot prims; they
are not connections. Item 3 keeps a Google handler in Elixir: a Scheme
handler would move the authorization code into Scheme.

Not done, with the reason:
- The listing card's copy machinery (ibuffer.scm). preview-show already
  shows the card. The copy is the isolation: the card reads a dormant
  buffer from its checkpoint without waking it, and a chat card is a
  projection, not the chat's text. docs/CHAT-LIST.md and the ibuffer
  comments state that a row preview never visits its source buffer. To
  show the source buffer itself changes that contract. RULING NEEDED.
- The popup's own stack of buffers (window.scm). The frame return stack
  holds whole arrangements for a popup that was entered. It does not
  hold the buffer under a popup. docs/POPUPS.md rule 4 and
  popup-move-test state that a dismiss shows the buffer underneath. The
  popup window's history is no substitute: a split copies the history of
  the host window, and a quiet show writes none. RULING NEEDED.
- The *peek-recent* store stays. The switcher reads it for its recent
  section. Only the unused command went.
- The two PTY runners: not approved. The owner approved the merge
  later the same day; the record follows.

**One PTY runner (2026-09-19, b96c18fd, worktree on d657abbb).** Item
16 is done. Compos.Core.Terminal is the one runner; proc.ex is gone.
`raw: true` (the default) is the terminal: raw stream to subscribers,
raw history, bounded transcript. `raw: false` is comint: TERM=dumb,
pty echo off, escape strip, one append per output chunk. Both kinds
share spawn, resize, send, mark, kill, restart, and the exit line. The
registry value holds the command and the kind, so a restart keeps the
kind. The Scheme primitives keep their names; no Scheme caller changed.
ProcRegistry and ProcSupervisor leave application.ex, so a live daemon
keeps two idle children until its next restart. A raw terminal now
counts as busy for buffer sleep. Net: -117 non-test lines.

**Popups after popper.el: the survey (2026-09-19, at d657abbb).** The
owner ruled: a popup is an ordinary buffer in an ordinary window, shown
through display-buffer; the popup window kind, its buffer stack and its
focus code go; preview windows stay as they are. What exists:

- window.scm, the popup window: `popup--class?`, `popup--by-class`,
  `popup-window`, `popup-buffer`, `popup-open?`, read from the frame
  locals `popup-window` and `popup-buffer` and from the `window-class`
  string.
- window.scm, the popup's buffer stack: `popup-stack`,
  `popup-stack-push!`, `popup-stack-drop!`, `*popup-dismissing*`,
  `popup-dismiss!`.
- window.scm, the focus code: `popup-remember!`, `popup-forget!`,
  `popup-layout-live?` (a return-stack entry with the reason `popup`),
  `popup-close!` (the return to the focus window), `popup-show-on`
  (selects the popup).
- window.scm, the move keys: the `popup-mode` minor mode, `*popup-keys*`,
  `popup-keys!`, `popup-move!`, `popup-move-left/right/up/down`, the
  `popup-side` local, `popup-default-side` (layouts.scm sets it).
- The commands: `popup-toggle` (M-\`), `popup-bufferize` (C-M-\`, with
  `popup-bufferize-hook` in groups.scm), `popup-buffer` (C-c p), and the
  popup branches of quit-window, delete-window, delete-other-windows and
  keyboard-quit (editor.scm).
- The display: the `popup` action and `display-buffer-popup!` already
  took the window chain; `popup-show` read the rule's side.
- Callers of the class float, which stay: `preview-show ... 'float`
  (`popup-show-quietly`, the listing card of ibuffer.scm), the `shaped`
  action (the panel and modal shapes of the ibuffer prompt and the chat
  prompt; `window-shape!` and `minibuffer-list-shape` in editor.scm),
  the peek verbs, `fill-candidate?`, `display--work-windows`,
  `layout-visible-window?`, `layout-target-on-change!`,
  `display-buffer-in-window!`, `switch-to-buffer-here!`, the window
  swap, `tile-windows!`, three group predicates in groups.scm,
  `scroll-other-window-target` (collect.scm), dismiss.scm, movie.scm,
  and `restore-buffer-runtime!` (the move keys came back on restore).
- telemetry.scm: `telemetry-toggle` read `popup-open?`, which no display
  made true, so the toggle only opened.
- Elixir: editor.ex `release_buffer` closes a window whose buffer wears
  the class; the render passes `window-class` and `window-style`. No
  other Elixir code knows the popup.
- UI: editor.css places `.window.popup-SIDE`; the PeekCard hook in
  app.js places the card. app.js has no popup focus code.
- Tests: popup-move-test.scm (the whole file), seven editor_test.exs
  tests (all seven red at d657abbb), and about 20 files that read
  `popup-open?`, `popup-buffer` or `popup-window` for the card.

Finding: no display reaches the popup window. The class float has two
live users, the row preview card and the shaped prompt surfaces. They
keep a small mechanism, the float, and the rest goes.

**Popups after popper.el: landed (2026-09-19).** Three commits on
d657abbb. Net lines are source files only, tests and docs excluded.

| Step | Commit | Net |
|---|---|---|
| The survey above | a93806c3 | 0 |
| The popup window goes; the card and the shaped prompts keep the float | dc0b9bb3 | -272 |
| popper.scm: popper-toggle, popper-cycle, popper-toggle-type | this commit | +195 |

Net: -77 source lines. docs/POPUPS.md states the model. The keys are
the popper README keys: C-\` toggles, M-\` cycles, C-M-\` changes the
type. C-\` ran group-next-buffer before; that command has no global key
now. popper-reference-buffers is empty by default, so no buffer is a
popup until the user names it. The popper default list made help-mode a
popup, and display-buffer-test's temporary-cover test then went red,
because the help window stopped being a work window.

## 11. Rules so it does not grow back

- A seam in core is one custom that holds a function. The provider lives in
  user config. No wrapper package.
- Scheme that is not the kernel lives in `scheme/packages/` at the project
  root. An app that the editor does not need is out of init.scm; the user
  init loads it by name.
- A package registers data at load and does nothing until its mode runs.
- A defcustom needs a second reader or a user story. Otherwise `define`.
- A command needs a key, a menu, a hook, or a caller. Otherwise it is a
  function.
- A primitive needs a production caller. A test is not a caller.
- One fact, one store. A second store is a cache and must be derivable in
  one call.
- A new mechanism must name the existing one it could not use.
- The kernel calls no package name. Packages add hooks; the kernel runs them.
- Comments state the contract. History goes in git.
- Tests: Scheme tests policy through the function; Elixir tests mechanism;
  no test presses a production chord.
