# Worktrees — spec and review (2026-08-20)

Scope: `apps/compos_core/priv/packages/worktrees.scm` (974 lines) and its
wiring in `editor.scm`, `packages/daemons.scm`, `packages/code.scm`,
`packages/agent.scm`, and `test/compos/worktrees_test.exs`.

What holds: the guards run in a safe order (unsaved → dirty → primary
dirty → branch). The finish prompt dedups by fingerprint. Optional
packages sit behind `boundp` guards. All workspace locals are in
`chat-identity-locals`. The tests cover create, list, land, rebase, and
isolation.

## Spec — how it should work

### Model

- A **project** is the primary checkout. A **workspace** is one task
  worktree of that project. One workspace serves one task.
- A workspace for project `/x/proj` named `NAME` lives at
  `/x/proj-worktrees/NAME` on branch `agent/NAME`. Worktrees sit next
  to the root, never inside it: inside they would shadow project files
  and churn the file watchers.
- One identity, three carriers: the worktree name, the branch, and the
  agent slug are the same string. Buffer authors, `COMPOS_AGENT`, and
  the branch all point at the same actor.

### Creation

There are three ways in; all converge on the same stamp.

1. **Agent spawn.** With `agent-worktree-isolation` on (the default),
   `chat-attach-agent!` calls `agent-worktree-opts` before
   `llm-session-open!`. A new thread in a git checkout gets its own
   worktree as `cwd`. An explicit `'isolated` in the attach opts wins
   over the defcustom. A thread that already carries a `cwd`, or a
   buffer outside any repository, stays alone. Reattach reuses the
   slug's existing worktree.
2. **`workspace-init` / code-mode.** From a primary buffer it creates
   the next free task workspace (`a1`, `a2`, …), opens the workspace's
   copy of the file, carries unsaved text into that copy, and points
   every window that showed the source at the copy. The primary buffer
   stays intact. From a buffer already inside a linked worktree it only
   stamps — isolation already exists.
3. **`workspace-new`** in the `*worktrees*` list creates one by name.

`worktree-create` must be idempotent against both leftovers: an
existing directory is reused, and an existing `agent/NAME` branch is
checked out rather than re-created (bug 1 today).

### The stamp

`workspace--stamp!` writes the durable identity onto a buffer:
`workspace-id`, `workspace-name`, `workspace-root`,
`workspace-project-root`, `workspace-backend`, `workspace-daemon`, and
`default-directory`. It enables `worktree-mode` (header line + window
class) and sets the buffer's group to the workspace. All of these are
`chat-identity-locals`: they survive reset, restart, and save. Git —
not a local — remains the source of truth for dirty/ahead/behind, so
state display survives reloads without extra persistence.

Every buffer whose file lives in a linked worktree gets the stamp on
`find-file`. The group's single chat inherits the stamp and the
workspace's LLM defaults (`workspace-chat-inherit!`). The LLM chat
namer's name becomes the workspace's human name — one naming call, not
two.

### Daemon ownership

Exactly one daemon owns a workspace. The registry (`daemons.scm`)
records the owner. On stamp:

- If another daemon owns it, navigate the browser to that daemon.
- If this checkout runs compos, provision a dedicated daemon whose
  code and cwd come from the workspace, and navigate to it.
- Otherwise the current daemon claims it.

Removal releases the claim. Rebase refuses to run when another daemon
owns the workspace ("open this workspace with C-x w").

### Working state

The `worktree-mode` header shows one status word from git:
`UNCOMMITTED` (dirty or unsaved) → `NEEDS REBASE` (behind) →
`UNMERGED` (ahead) → `READY TO TEARDOWN`, plus the counts. The
`*worktrees*` list shows one row per worktree: branch, ahead, dirty,
owner (primary / agent status / chat / no thread), path.

After every agent turn, `workspace-finish-reminder!` announces the
counts and refreshes the headers. When the workspace goes clean
(0 dirty, 0 unsaved), it offers land-and-teardown **once per
fingerprint** (sha + counts): a repeated clean state does not nag.

### Finish — land, rebase, cancel

- **Land** (`L`, or the finish prompt): refuse on unsaved, dirty,
  dirty primary, or no branch. If behind, rebase onto the base first;
  a rebase that leaves dirt keeps the workspace ("needs attention").
  Then `git merge --no-ff agent/NAME` into the primary, remove the
  worktree, release the daemon claim, and retire the buffers. Any
  failure keeps the workspace; no step may leave the primary checkout
  mid-merge (bug 2 today).
- **Rebase** (`r`): the machine does not resolve conflicts. It opens
  the workspace's chat and hands the agent a rebase prompt: inspect,
  rebase onto the base, resolve preserving both intents, test, report
  — and never land or tear down.
- **Cancel** (`d` then `x`): removes only a clean worktree. The branch
  stays as a recovery path; the daemon claim does not.

### Retire

After removal, file buffers of the workspace are killed (they were
clean by the guards). Non-file buffers — the chat — keep their content
but lose all workspace locals and return to the project's group. The
conversation survives; the workspace identity does not.

### Invariants

- The primary checkout is never removed, never merged into while
  dirty, and never edited by an isolated agent.
- Every workspace buffer survives a daemon reload: the locals restore,
  and the mode setup rebuilds header and window class from them.
- One workspace ↔ one branch ↔ one slug ↔ one chat ↔ one owning
  daemon.
- Git is the source of truth for progress; buffer locals carry only
  identity.

## Bugs

### 1. Cancel breaks re-create

`workspace-cancel` keeps branch `agent/NAME` as a recovery path. But
`worktree-create` (`worktrees.scm:33`) always passes `-b`, and git
refuses `-b` when the branch exists. A cancelled name can not come
back. `worktree--next-task-name` (`:757`) checks only directories, so
after you cancel `a1`, the next `workspace-init` picks `a1` again and
fails. Land-and-teardown sets the same trap: it never deletes the
branch.

Fix: when the branch exists, run `git worktree add DIR agent/NAME`
without `-b`.

### 2. A failed merge leaves the primary mid-merge

`workspace-land-and-teardown!` (`:338`) and `workspace-land` (`:585`)
run `git merge --no-ff` and only print a message on failure. A conflict
leaves `MERGE_HEAD` in the primary checkout with no
`git merge --abort`. The window is small — the primary must change
between the dirty check and the merge — but the blast radius is the
user's main tree. The rebase path (`:329`) has the same shape and
strands only the worktree.

Fix: on a failed merge, run `git merge --abort` and report; on a failed
rebase, offer `git rebase --abort`.

### 3. Long git operations die at the shell time limit

`shell-command->string` without a callback blocks, then kills the
command at the limit. The land path runs `git rebase` and `git merge`
this way. A kill mid-rebase leaves the worktree in a partial rebase
state.

Fix: move these two calls to the callback lane (e5fc2e7) or raise the
limit for them.

### 4. An untracked file loses its content in the task copy

`code-worktree--open-copy!` (`:854`) copies source text only when
`buffer-modified?`. A saved-but-uncommitted file is not in HEAD, so the
new worktree lacks it, and the copy opens an empty buffer where the
user's file was.

Fix: copy when the target file does not exist, not only when the source
is modified.

## Smaller items

- `worktree--dirty` (`:74`) counts lines of merged stderr as dirty
  entries when git fails. An error reads as "N dirty". Guard on git's
  exit or on the porcelain shape.
- `workspace-new` via M-x from a non-list buffer passes `#f` as root
  into `worktree-create` and crashes. It also accepts spaces and
  slashes in the name, which git rejects with a raw error. Guard the
  root and sanitize the name.
- `worktree--daemon-port` (`:187`) returns "80" for
  `http://localhost:4004/`. A trailing slash defeats the port parse.
- `daemon-claim-workspace!` is check-then-write on the registry file
  with no lock. Two daemons that both see no owner both claim; the
  last write wins. Concurrent sessions make this reachable.
- Every `find-file` in any repo runs `git worktree list --porcelain`
  synchronously in the Session (`:257`). A `*worktrees*` refresh shells
  2–3 git commands per row plus a full buffer scan. Fine at current
  scale; this is the first place list latency will show.
- `code-worktree--open-copy!` binds `path` and never uses it.

## Test gap

Add the case behind bug 1: cancel a workspace, then create one with the
same name.
