# Code browser: fly through the codespace

Branch `worktree-codebrowser`, 2026-08-30. Reference: `/Users/svs/src/codescope`
(the first vision) and Linear "Code browser" CB1-CB10.

> **Status (2026-09-24):** only these docs merged to `main`. The scope store,
> `scope-mode`, the `scope-*` commands, and the provider chain are not built.
> The popup functions that 3.4 names (`display-buffer-popup!`,
> `popup-show-quietly`) no longer exist. `peek-show!` is now in `window.scm`.

The product is the understanding of a codebase, not a file tree. The reader
sees a summary at every level: the project, a directory, a file, a
definition, a change. Every summary stays true to the code, and every name
in a summary is one key away from the code it names.

## 1. What codescope did, and what of it exists here

| codescope piece | what it is | compos today |
|---|---|---|
| `Target` + `Git.Watcher` | one target dir, a debounced fs event on PubSub | `project-current`, `watch-path!`, `fs-change-hook` (editor.scm:2170) |
| `/diff` + explain button | live `git diff HEAD`, LLM explanation streamed into a pane | `diff-mode` cards + `define-diff-backend` + fs watch (diff-mode.scm); `diff-explain` (`?`) explains the whole diff in a separate buffer |
| `/browse` file view | Monaco, fold bodies, sexp nav, scope tint | `code-browse` (code.scm), tree-sitter or indentation, tint, folds |
| `Docs` `.codescope/*.md` | hand-editable overview, files sorted by `NN-` prefix | nothing; morg-mode is the renderer to use |
| `Docs.autolink/1` | every `path/to/file.ext` in prose is a link, verified on disk | nothing (CB8 still open) |
| `FileDocs` | per-file synopsis cached at `.codescope/files/<rel>.md` | nothing |
| `DirDocs` | per-directory card grid cached at `.codescope/dirs/<rel>.html` | nothing |
| `ChangeExplainer` | one prompt: explain the diff and rewrite the file doc | `diff-explain` explains the diff; it rewrites no file doc |
| `Bootstrap` | first run: the agent reads the repo and writes the overview set | nothing |
| LSP jump (planned) | never built | `lsp.scm` M-. through the code.scm seam; `scheme-ide.scm`; `definition-peek` in morg |

codescope kept every summary as a file in the target repo. It regenerated a
summary only on a button. The roadmap wanted hash-keyed auto-regeneration
and never got it. This plan builds the freshness first, because a stale
summary is worse than none.

## 2. What M-. does in a document today

`morg-mode` binds `M-.` to `definition-peek` (morg.scm). The command
reads the name at point, calls `(definition-locate NAME)`, and shows the hit
in the other window. `M-.` again goes there. The window stays after other keys:
peek.scm no longer closes it.

`definition-locate` (peek.scm) asks one provider: `scheme-ide--find-def`.
So in a document `M-.` works on a Scheme name and on nothing else. An
Elixir function, a Rust struct, a module name, a file path: "No definition
of X".

Source buffers are different. There `M-.` is `code-goto-definition`
(code.scm): it follows a link at point first, else LSP when the buffer has an `lsp-server` local, else a scan of
the same buffer for a defining word. Neither answers for a document.

So the mechanism the user remembers is real and it is the right shape. It
needs providers.

## 3. Design

### 3.1 The scope store

One directory per project holds the summaries: `<root>/.compos/scope/`.

```
.compos/scope/
  project.md            what the project is; worth knowing; how to run
  recent.md             what changed lately (from git log + the working diff)
  dirs/<rel>.md         one per directory: what lives here, one card per entry
  files/<rel>.md        one per file: what it does, why, who calls it, gotchas
  changes/<rel>.md      the explanation of the current working-tree diff of a file
```

Every file is morg. Every file starts with directives:

```
#+scope: file
#+path: scheme/packages/code.scm
#+source: 9f1c2a...      the git blob sha of the input when the summary was written
#+inputs: a1b2 c3d4      for a dir: the shas of the child summaries it read
#+model: claude-sonnet-5
#+written: 2026-08-30T12:00:00Z
```

`morg-scan` already parses `#+name: value` lines as directives
(morg.scm:48). No new parser.

Why in the repo and not in `~/.compos`: the summaries are documentation.
The user hand-edits them, commits them, and an agent reads them as
context. codescope made the same call. Whether `.compos/scope` is committed
or ignored is the project's choice; the store works either way.

### 3.2 Freshness: content-addressed, lazy, and queued

The input key of a file summary is the git blob sha of the file
(`git ls-files -s` gives every sha in one call; `git hash-object` for an
untracked or modified file). The key of a directory summary is the sorted
list of its children's summary shas plus the entry list. The key of
`project.md` is the root directory summary sha plus `HEAD`. The key of
`changes/<rel>.md` is the sha of the file's working-tree diff text.

A summary is fresh when its `#+source` equals the current key. That is one
comparison, no clock, no mtime.

Three ways a summary refreshes:

1. **On view.** Opening a scope buffer for a stale node queues that node.
   The buffer shows the stale summary with a `stale` badge until the new
   text lands.
2. **On change.** `fs-change-hook` marks the changed files stale and queues
   them if `scope-auto-refresh` is on (default on, with a per-project
   budget: `scope-refresh-budget` calls per hour, default 60). Directory
   and project summaries refresh only after their children settle, so one
   save costs one file call, not a chain.
3. **By hand.** `g` in any scope buffer, `M-x scope-refresh` for a node,
   `M-x scope-bootstrap` for the whole tree.

The queue is one Scheme list with one in-flight job (`scope--queue`,
`scope--running`). A job calls `(llm-with-preset 'summarize PROMPT HANDLER)`
for a file and `(llm-with-preset 'explain ...)` for a change. A directory
or the project uses `llm-with-tools` with the `explain` preset, so the
agent reads the files itself, the way codescope's bootstrap did. The
preset, not the model, is what the job names; the preset table (3.6)
picks the model, and a project changes it in `.project.scm`.
The handler writes the morg file, sets `#+source`, and redraws every
scope buffer that shows the node. The queue drops a job whose key changed
while it waited (the file changed again) and re-queues the newest key.

Prompts are the four codescope prompts, moved to `priv/prompts/scope-*.md`
and rewritten to ask for morg: no headings in a file synopsis, a card per
entry in a directory summary, paths inline as `path/to/file.ext`.

### 3.3 Every name is a link: the provider chain

`definition-locate` becomes a chain. A provider is `(NAME KIND) -> (SOURCE-KIND TARGET BYTE-POS)` or `#f`.

```scheme
(define-definition-provider! 'scheme-ide scheme-ide--find-def)   ; exists
(define-definition-provider! 'path      scope--path-locate)      ; new
(define-definition-provider! 'outline   scope--outline-locate)   ; new
(define-definition-provider! 'lsp       lsp--workspace-locate)   ; new
```

- **path**: `apps/x/y.ex`, `y.ex:42`, `lib/foo.ex#L42`. Resolve against the
  document's `default-directory`, then the project root. A hit only when
  the file exists, so a link is never dead (codescope's rule). This is CB8
  done in Scheme, at the point of use, with no HTML pass.
- **outline**: a project-wide name index built from `code-outline` rows
  (LINE KIND NAME DOC) for every tracked source file, cached per blob sha
  in `.compos/scope/index.etf` (or a plain sexp file). Building it opens
  each file in a temporary buffer once; the cache makes the second run
  free. `Elixir.Module.fun`, `Mod.fun/2`, `fun` all resolve.
- **lsp**: `workspace/symbol` when a server is attached for the project.
  One new request wrapper in lsp.scm over `lsp-buffer-request`.

Order: path, scheme-ide, lsp, outline. The first hit wins.
`symbol-at-point` needs one change: a document reads a wider alphabet
(`/`, `.`, `:`, `#`) so a path and a qualified name are one symbol.

`definition-peek` already handles the rest: `M-.` again to go, `M-,`
back via the marker stack. Where it shows the hit is 3.4: the popup.

### 3.4 The surface: scope-mode over Dired, a side window, popup definitions

Decided 2026-08-30: no new table. Dired is the table of a directory
(`priv/dired.scm`, a `define-list-mode!`). `scope-mode` is a minor mode
that toggles onto a Dired buffer or a file buffer, the way `diff-mode`
toggles onto them (git.scm:197). `docs/CODEBROWSER.md` has the stories
and the screens.

What the mode adds:

- **A `summary` column in Dired**, the way Dired got the `vc` column: the
  first sentence of the entry's summary, or a badge (`?`, `stale`, `~`,
  `pinned`). Dired's `'columns` and `dired-cells` grow the column; it
  draws only when the buffer wears scope-mode. `dired-match?` reads the
  one-liner too, so `/` narrows on it. The column reads the store once
  per draw through the row context (docs/LISTS.md rule 1).
- **The side window**: the popup (`display-buffer-popup!`,
  editor.scm:4965; docs/POPUPS.md) showing `*scope*`, a morg buffer in
  `scope-doc-mode`. It follows point: Dired's `'preview` hook
  (editor.scm:1309) and a post-command hook in a file buffer, with the
  switcher's debounce. In a file it puts the outline row and the
  paragraph about the definition at point first.
- **Definitions in the popup**: `definition-peek` shows its hit in the
  popup over the summary (popper's stack), `q` brings the summary back,
  `M-.` again goes there. The popup peek machinery already exists in
  editor.scm (`peek-show!`, `popup-show-quietly`, POPUPS.md rule 10):
  peek.scm calls it when the reader is in the side window or a morg
  document, instead of growing popup code of its own. The
  split-the-frame path stays for a code buffer.
- **Commands**, all `M-x`: `scope` (Dired at the root, mode on), `scope-here`,
  `scope-mode`, `scope-doc` (select the side window), `scope-recent`,
  `scope-refresh`, `scope-bootstrap`, `scope-find` (complete over the
  outline index, visit). No global key.
- **Inheritance**: a buffer opened from a listing with scope-mode on
  wears scope-mode. `dired-visit-with-group` carries the local.

What is gone from the earlier draft: the `*scope: REL*` list modes, the
`h`/`l`/`j`/`k` flight alphabet, the file outline level (Dired `RET` peeks
the file; `imenu` and `code-browse` are the outline), the `c`/`d`/`r`/`g`
keys.

### 3.5 Changes: the diff explains itself

diff-mode has the cards and the watch. Add:

- `e` on a file card: `diff-explain`. The job sends the file's diff, the
  file, and the current `files/<rel>.md` in one prompt (codescope's
  `ChangeExplainer` shape) and gets two sections back: what changed, and
  the updated file doc. The first shows under the card as a folded
  `explanation` block; the second lands in the store as the new synopsis
  and the store marks it fresh. One call updates both.
- `recent.md` regenerates from `git-log` (20) plus the working diff
  summary, keyed on `HEAD` plus the diff sha. This is the "what has the
  agent been doing" page.

### 3.6 Presets: the model router, summonable with `@name`

Reference: gptel's presets (karthink, "stdin | LLM | stdout",
youtube.com/watch?v=xHEnWvKmSKM). A preset is a named collection of LLM
settings applied to one query as a unit: model, system prompt, tools,
effort. It applies globally, to a buffer, or to one request with
`@name` anywhere in the prompt. The `@name` cookie is removed before the
send, highlighted in the buffer, and completed on `@`.

compos already has half of it. `define-preset!` (mcp.scm:79) names a
tool collection; `'chat-presets` holds a buffer's choice;
`llm-set-preset` picks one; `chat-presets-changed!` reattaches a live
ACP session. code-mode holds the other half as three knobs:
`code-presets`, `code-model`, `code-instructions` (code.scm:939-990).
The plan joins them: one preset table, and the model router is what a
preset says about its model.

```scheme
;; packages/models.scm — tiers: a model alias, with an effort
(define *model-tiers*
  '((fast   "claude-haiku-4-5-20251001")
    (medium "claude-sonnet-5")
    (strong "claude-opus-5" effort "high")))

;; packages/presets.scm — a preset is a plist; every key is optional
(define-preset! 'coding
  'description "Edit code in this editor with the structural tools"
  'model 'strong                       ; a tier or a model id
  'servers '(compos)                   ; MCP servers to mount (today's presets)
  'tools '(code-outline code-read eval-scheme apropos act
           web/fetch)                  ; the tools the model holds: editor tools
                                       ; by define-tool! name, MCP tools as
                                       ; server/tool
  'system code-instructions            ; a string or a thunk
  'parents '(compos))

(define-preset! 'summarize 'description "A file or directory synopsis"
  'model 'fast 'tools '() 'system (prompt-file "scope-file"))
(define-preset! 'explain 'description "What a change does and why"
  'model 'medium 'tools '(read-file code-outline code-read)
  'system (prompt-file "scope-change"))
(define-preset! 'chat 'description "The default chat" 'model 'medium)
```

Two keys say what the model can call. `'servers` names MCP servers to
mount; it is the old third argument. `'tools` names the tools the turn
offers: an editor tool by its `define-tool!` name (tools.scm:25), an MCP
tool as `server/tool`, a whole server as `server/*`. No `'tools` key
means every tool of the mounted servers and every editor tool, as today.
`'tools '()` means none: a summary job holds no tool. `'parents` merge
both lists. The filter runs in one place, `chat-live-tool-specs`, which
is what the API lane freezes into `'chat-tool-specs` (chat.scm:427) and
what `llm-with-tools` sends; an ACP session gets the same list as its
`mcpServers` plus the tool names it may call. The effects grants of
agent-permissions.scm still apply on top: a preset offers a tool, the
grant decides whether it runs without asking.

The three-argument form `(define-preset! NAME DESC SERVERS)` keeps
working: it is `'servers SERVERS`. Every registered MCP preset is a preset
with only tools, so `compos`, `web`, and the user's own stay valid.

Resolution of one field, `(preset-get NAME KEY [BUF])`, first hit wins:

1. the one-shot: the `@name` cookies of the turn (below)
2. the buffer local `'preset-<key>` (`M-x set-preset-field`)
3. `.project.scm`: `(project-preset! 'coding 'model "gpt-5.6-sol")` and
   `(project-tier! 'strong "gpt-5.6-sol")`, sugar over `project-default!`
   (project.scm:64), so the values ride the existing defaults plist and
   apply to the project's buffers as locals
4. the preset, then its `'parents` in order
5. the global tables (`defcustom`, group `models`)

`(preset-model NAME [BUF])` resolves `'model` and then the tier on the
same layers; `llm-connector-for-model` (editor.scm:6269) picks the lane.
A tier's `effort` rides along unless the preset names its own.

Where a preset applies:

- **Global**: `M-x set-preset` with no buffer sets `*default-preset*`.
- **Buffer**: `M-x set-preset` in a chat or an llm-mode buffer writes
  `'chat-presets` (a list, as today) and the model/effort locals through
  `chat-switch!` (editor.scm:7282), which switches in place when the
  backend can take the model and reattaches otherwise. That is the
  existing `llm-set-preset` with a wider preset.
- **One request**: `@coding` anywhere in the input. `agent-send`
  (agent-session.scm:141) and `llm-mode` (`M-o`) read the cookies before
  the send: the cookies come out of the text, the preset's system parts
  join the turn's `chat-system-prompt-parts` (chat.scm:578), its tools
  join `chat-presets-of` for the send, and its model reaches the lane.
  On the API lane every field is one-shot: the next turn is back to the
  buffer's own settings. On a stateful ACP session the model changes in
  place when `chat-model-takeable?` says yes, else the echo area says
  the preset holds for the rest of the session; tools on ACP are fixed
  at session start, so a tool change there is the reattach path
  `chat-presets-changed!` already handles. Several cookies stack, last
  wins per field (gptel allows one; the table makes stacking free).
- **A call from Scheme**: `(llm-with-preset NAME PROMPT HANDLER)` runs
  the tool loop (`llm-tools`, session.ex:1332, model as the seventh
  argument, which exists) with the preset's tools, its system text, and
  its model; a preset with `'tools '()` takes the plain `llm-with-model`
  path (session.ex:1313). `llm-with-tools` becomes `llm-with-preset`
  with the `chat` preset. The scope jobs name `summarize` and
  `explain`; nothing outside models.scm names a model id.

The input surface: a `chat-input` capf source (`add-capf!`,
editor.scm:3356) offers `@name` with the description as the annotation
when the word at point starts with `@`; a face `preset-cookie` paints a
cookie that names a real preset (the same paint pass that draws the
input). `M-x presets` lists name, description, model, tier, connector,
tools, and which layer answered each field; `RET` sets the buffer
preset, `g` re-reads `.project.scm`.

`code-model`, `code-agent-model`, and `code-presets` become views of
the `coding` preset: an empty value asks the preset. `chat-tool-list`
(mcp.scm:547) shows the filtered list and names the preset that cut it. `(llm-model)` is
the `chat` preset's model.

### 3.7 Elixir

None expected. Every mechanism exists: `llm`, `llm-with-model`, `llm-with-tools`,
`git-*` primitives, `shell-command->string`, `watch-path!`, `fs-change-hook`,
`read-file`, `write-file!`, `list-dir`, `code-outline`, `imenu-rows`,
`lsp-buffer-request`, the list mode, morg. The one candidate is a content
hash primitive; `git hash-object --stdin` through the shell covers it.

## 4. Phases

Each phase lands on `worktree-codebrowser` with focused tests only
(`priv/tests/scope-test.scm` and one ExUnit file for the key dispatch
path). No suite runs until the merge.

### P0. Presets and the model router

Files: `packages/models.scm` (tiers, resolution), `packages/presets.scm`
(the table, `@` cookies, capf, face, `M-x presets`), `packages/mcp.scm`
(`define-preset!` grows keys; `llm-set-preset` becomes `set-preset`),
`packages/project.scm` (`project-preset!`, `project-tier!`),
`packages/agent-session.scm` and `editor.scm` llm-mode (cookie read
before the send), `packages/chat.scm` (system parts from the preset),
`packages/tools.scm` (NAME on `llm-with-tools`), `packages/code.scm`
(the `coding` preset owns the three knobs), `themes.scm`
(`preset-cookie`), `init.scm` (load order: models, presets, after
project.scm and before code.scm).

Accept: `(preset-model 'summarize)` answers the global tier; a
`.project.scm` with `(project-preset! 'summarize 'model "x")` answers
"x" in that root and the global outside it; the buffer local wins over
both; `@coding fix the loop` sends "fix the loop" with the coding model,
system, and tools on the API lane and the buffer is unchanged on the next
turn; on an ACP session the model switches in place or the echo area says
it holds; `@` in the input completes preset names; `M-x presets` shows
the layers; the old three-argument `define-preset!` still loads
`~/.compos/ai-config.scm` files.

Tests: `priv/tests/presets-test.scm`, pure resolution over fixture
tables and a temporary root with a `.project.scm`; the tool filter
(editor name, `server/tool`, `server/*`, `'()`, parents merged); the cookie parser
(text out, names out, unknown `@word` stays in the text); the send path
through `KeyDispatch.handle_key/1` with the stub backend
(`AIMAX_CHAT` replay lane) asserting the model and system the turn
carried.
### P1. Providers: M-. in a document reaches the code

Files: `packages/peek.scm` (chain), `packages/scope.scm` (new: path and
outline providers), `packages/lsp.scm` (workspace/symbol), `editor.scm`
(document symbol alphabet).

Accept: in a morg buffer, `M-.` on `scheme/packages/code.scm`
peeks the file; on `code.scm:423` peeks line 423; on `code--goto-definition`
peeks the Scheme definition; on `Compos.Core.Git.diff` peeks git.ex; on a
name only elixir-ls knows, the LSP answers when attached. A name that
resolves nowhere says so and opens nothing.

Tests: `definition-locate` per provider with fixture files; the chain
order; the no-hit case; the alphabet.

### P2. The store and freshness

Files: `packages/scope.scm` (store, keys, queue), `priv/prompts/scope-*.md`.

Accept: `(scope-key 'file REL)` equals the blob sha; `(scope-fresh? NODE)`
flips when the file changes; `(scope-refresh! NODE)` writes a morg file
with the directives; a change on disk re-queues the file, not the chain;
the budget stops the queue and says so in the echo area.

Tests: keys from a fixture repo; `#+source` round trip; queue drop and
re-queue; the LLM seam stubbed with a lambda (`*scope-llm*`), so no test
spends.

### P3. scope-mode, the side window, popup definitions

Files: `packages/scope.scm` (the minor mode, `scope-doc-mode`, the
follow hooks, the commands), `priv/dired.scm` (the `summary` column,
`dired-match?`, the local carried by visit), `packages/peek.scm`
(route `peek--show!` through editor.scm's `peek-show!`), `themes.scm`
(badges).

Accept: `M-x scope` opens Dired at the root with the column and the
popup on `project.md`; `n`/`p` move the side window; `RET` on a file
peeks it with the mode on and the side window on its summary; `M-.` in
the side window shows the definition in the popup and `q` brings the
summary back; `M-x scope-mode` in a plain file opens and closes the side
window; the mode survives a restart.

Tests: through `KeyDispatch.handle_key/1` with dummy `<f9>` bindings;
Dired's own tests unchanged; the column's cells over a fixture store;
the follow hook writes `*scope*` for the row at point; the restore
path.

### P4. Changes

Files: `packages/diff-mode.scm` (explain block, `e`), `packages/scope.scm`
(`recent.md`, `changes/`).

Accept: `e` on a card shows the explanation under it and updates the file
synopsis in one call; `recent.md` regenerates when `HEAD` moves.

### P5. Bootstrap and the project page

`M-x scope-bootstrap` on an empty store: files first (bounded by the
budget, largest directories last), then directories, then `project.md`.
Progress in the modeline of the scope buffer. `project.md` opens as the
front page of `M-x scope` above the root list.

### P6. Verify in the editor, then docs

Drive the running daemon over the socket (compos-debug skill), read buffer
text and locals, screenshot the three surfaces, write `docs/SCOPE.md`,
close CB8/CB9 in Linear or mark what this replaces.

## 5. Decisions for the user

1. `.compos/scope/` in the repo (recommended, hand-editable, committable)
   or `~/.compos/scope/<root>/`.
2. Auto-refresh on by default with a budget of 60 calls per hour per
   project, or off until `G`.
3. Decided 2026-08-30: presets with a model router (3.6), gptel-shaped.
   Presets `coding`, `summarize`, `explain`, `chat`; tiers `fast`,
   `medium`, `strong`; `@name` in the input summons one for a turn;
   `.project.scm` overrides preset fields and tiers. Open: the global tier
   defaults named above.
4. Should `M-.` in a document GO (pop-to-buffer) or PEEK (current
   `definition-peek`)? The plan keeps peek: a document names many things
   and the reader checks more than they follow.

## 6. Landmines

- A headless `(find-file)` applies no auto-mode, so `code-outline` on a
  file opened for indexing needs `code--pick-backend!` (memory:
  structural-code-tools). The outline provider must open files through a
  helper that sets the mode.
- `plist-get` throws on `#f`; `string->number` returns `:error`. Directive
  reads go through `morg-directive-info`, never a raw plist.
- Async callbacks from `llm` run on another lane; a handler that touches
  buffers must not close over local env frames (lsp_cb rule). Handlers
  call named top-level functions.
- One fs-change burst on a repository can name hundreds of files. The
  hook marks stale in one pass and queues nothing itself; the queue
  drains from a timer.
- Every list draw reads the mode once (docs/LISTS.md). The summary column
  reads the store once per draw, not per row.
- Never assert a production binding; bind dummy `<f9>` keys.
