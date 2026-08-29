---
name: compos-restart
description: Get a change into the running compos daemon. Use whenever a change must reach the running editor: after editing priv/*.scm or any Elixir source, when the daemon is wedged or not answering, or before verifying behaviour in the real editor.
---

# Getting a change into the running daemon

**Do nothing.** In development the daemon reloads itself, and a restart is
almost never the answer.

`Compos.Core.Hotload` (apps/compos_core/lib/compos/core/hotload.ex) watches
`apps/*/lib`, `apps/compos_core/priv`, and the config home. A save arms a 200 ms
debounce, and the burst then goes to the reloader that fits the file.

| You changed | What happens on save | Cost |
|---|---|---|
| Any `priv/**/*.scm`, including `editor.scm` | the changed top-level forms evaluate; modes refresh | under 1s |
| `~/.compos/init.scm`, `ai-config.scm`, `~/.compos/packages/*.scm` | the same | under 1s |
| Any `.ex` or `.heex` under `apps/*/lib` | a child `mix compile` writes the beams; the VM swaps in the changed modules, load before purge, so no call finds a module missing; a compile error changes nothing | 1-3s |

The echo area states the result: `3 files, 12 forms reloaded`, `1 module
recompiled`, or the first line of a compile error. The same line lands in
`*messages*`, so `curl -s http://localhost:4004/raw/*messages*` reads it.

## What a Scheme reload actually does

It is not `(load PATH)`. The daemon reads the file, compares each top-level
form against what that file last held, and evaluates only the forms whose text
changed. A file with one changed line costs one form, so `editor.scm` costs
what its diff costs.

It then re-runs mode setup on the buffers already open in a mode the reload
redefined, and on no others. `reload-begin!` and `reload-finish!` in
`editor.scm` own that policy; `define-mode` and `register-minor-mode!` name the
modes they touch. This is the work desktop restore does, so the same rule
holds: a setup fn rebuilds presentation from the buffer's locals, and stacks
nothing twice. A setup fn that breaks that rule breaks hot reload.

The refresh reads the `define-mode` form, not the file. If you change a helper
the setup fn calls and leave the `define-mode` form alone, the new helper is
live but the open buffers keep what the old setup installed. Re-enter the mode
there (`M-x <mode-name>` twice, or `M-x normal-mode`) to see it.

## Asking for a reload by name

```sh
mix compos.reload apps/compos_core/priv/packages/notmuch.scm
mix compos.reload --all
```

`M-x reload-file` is the same reload from inside the editor, with completion
over the stdlib, the bundled packages, and the user packages. Reach for either
only for a file outside the watched roots, or when you want to name the file
yourself.

## When a restart IS required

Three changes, and nothing else. Nothing reloads them in place:

- a new dependency in a `mix.exs`,
- a change to a supervision tree or to application start,
- a NIF rebuild (`apps/compos_core/native/compos_ts`).

Then use `M-x restart-daemon`, or evaluate `(daemon-restart!)` over the socket.
It compiles first, refuses the restart if the tree does not compile, saves the
desktop, respawns, and stops this VM. Buffers, windows and theme come back
from `~/.compos/desktop.etf`.

Never `pkill -f "mix run"`. The user runs concurrent sessions and worktree
daemons out of this tree, and a broad kill takes theirs down too. Never
hand-roll a kill plus a fixed `sleep`: the sleep is a guess, and a
backgrounded `mix run` gives no failure signal.

## When the daemon does not come back

```sh
bin/compos state                                  # answers = it is up
tail -40 ~/.compos/daemon.log
pgrep -f "mix run --no-halt"                     # process alive but silent = still booting
```

A process that lives while nothing answers is a boot still in progress. The RPC
socket opens last, after `Compos.Core.Session` loads the whole Scheme corpus, so
`pgrep` proves nothing about readiness. Only `ping` does.

Compile errors surface in `daemon.log`, not on your terminal, because the new
daemon starts detached. Run `mix compile` first when you suspect one: it fails
in 1s and leaves the old daemon serving.

## Verifying from a worktree

A second daemon on `~/.compos` writes `desktop.etf` and clobbers the user's
session. Use the isolated one instead — its own port, home, and socket:

```sh
COMPOS_VERIFY=1 mix run --no-halt >> /tmp/compos-verify.log 2>&1 &
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}' | nc -U /tmp/compos-verify.sock
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"shutdown","params":{}}' | nc -U /tmp/compos-verify.sock
```

Hot reload runs there too, so a save reaches the verify daemon the same way.

## What boot costs, and what makes it slow

A healthy boot is about 3s: roughly 1.5s of mix overhead and compile check,
1.5s of application start, and whatever the user's config spends on top.
Measure before you accept a slow one:

```sh
time mix compile                    # ~0.8s when up to date
time mix run --no-start -e ':ok'    # ~0.5s: mix overhead alone
```

If those are fast and boot is not, the cost is inside application start. Time
the supervision children directly rather than guessing. Start `:compos_scheme`,
then add `Compos.Core.Application`'s children one at a time under your own
supervisor with `:timer.tc`, pointing `COMPOS_HOME` at a scratch copy of the
real home. Always probe a copy.

Two known costs live on the boot path:

- **The Scheme corpus.** `Session.init/1` evaluates about 32k lines of Scheme
  synchronously. There is no cache and no mtime check. It costs ~1.5s and every
  boot pays it. This is the largest remaining item.
- **User config shell-outs.** `load_init/1` evaluates `ai-config.scm` and
  `init.scm` from the config home. Top-level forms there can spawn processes,
  and each `shell-command->string` blocks for up to 15s. `doppler.scm` answers
  this by fetching a whole config in one call and caching every name, so ten
  lookups cost one process. Any new package that shells out at load time must
  do the same.

Nothing else on the boot path does network I/O. MCP and LSP only register at
load; `llm_db` refreshes under a Task; the desktop restore is async and runs
after the socket opens.

Slow lane jobs report themselves. `Compos.Core.Lane` logs any job over 250ms
with its lane and label, so `grep "slow job" ~/.compos/daemon.log` names a stall
that happens after boot. `Session.init` runs no lane jobs of its own, so
nothing inside it is timed.
