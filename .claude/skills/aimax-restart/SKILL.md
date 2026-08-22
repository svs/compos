---
name: aimax-restart
description: Restart the ai-max daemon, or hot-reload Scheme into it without a restart. Use whenever a change must reach the running editor — after editing priv/*.scm or any Elixir source, when the daemon is wedged or not answering, or before verifying behaviour in the real editor.
---

# Getting a change into the running daemon

Pick the cheapest path that reaches the change. A restart is the last resort,
not the default.

| You changed | Do this | Cost |
|---|---|---|
| One `priv/packages/*.scm` file | `mix aimax.reload apps/aimax_core/priv/packages/foo.scm` | under 1s |
| Several Scheme files | `mix aimax.reload --all` | ~2s |
| `priv/editor.scm` | `mix aimax.restart` | ~8s |
| Any Elixir source | `mix aimax.restart` | ~8s |

`editor.scm` is core bootstrap policy, so `mix aimax.reload` refuses it by name
(apps/aimax_core/lib/mix/tasks/aimax.daemon.ex:91). Restart instead.

## Restart

```sh
mix aimax.restart                 # the user's daemon on ~/.aimax
mix aimax.restart --home ~/.aimax-web
```

The task saves and stops the daemon over RPC, waits for it to go, starts a new
one detached, and waits for `ping` to answer. It prints `ai-max restarted` only
when the new daemon serves. Read that line as the success condition.

Never `pkill -f "mix run"`. The user runs concurrent sessions and worktree
daemons out of this tree; a broad kill takes theirs down too. `mix aimax.restart`
addresses one daemon by its home.

Do not hand-roll a kill plus a fixed `sleep`. The sleep is a guess, and a
backgrounded `mix run` gives no failure signal.

## Reload

```sh
mix aimax.reload apps/aimax_core/priv/packages/notmuch.scm
mix aimax.reload --all
```

Registrations replace by name, so a reload does not stack duplicates. It
re-evaluates the file's top-level forms: new commands, keymaps, faces, and mode
definitions land at once.

A reload does NOT re-run mode setup on buffers that are already open. A buffer
keeps the keys and overlays its setup fn installed earlier. To see a mode change
in an open buffer, re-set the mode there, or restart.

## When the daemon does not come back

The task waits 10s and then raises `daemon did not come back`. That message means
the wait expired, not that the daemon failed. Check before you act:

```sh
bin/aimax state                                  # answers = it is up
tail -40 ~/.aimax/daemon.log
pgrep -f "mix run --no-halt"                     # process alive but silent = still booting
```

A process that lives while nothing answers is a boot still in progress. The RPC
socket opens last, after `Aimax.Core.Session` loads the whole Scheme corpus, so
`pgrep` proves nothing about readiness. Only `ping` does.

Compile errors surface in `daemon.log`, not on your terminal, because the new
daemon starts detached. Run `mix compile` first when you suspect one; it fails in
1s and leaves the old daemon serving.

## What boot costs, and what makes it slow

A healthy boot is about 2s of Elixir plus whatever the user's config spends.
Measure before you accept a slow one:

```sh
time mix compile                    # ~0.8s when up to date
time mix run --no-start -e ':ok'    # ~0.5s: mix overhead alone
```

If those are fast and boot is not, the cost is inside application start. Time the
supervision children directly rather than guessing — start `:aimax_scheme`, then
add `Aimax.Core.Application`'s children one at a time under your own supervisor
with `:timer.tc`, pointing `AIMAX_HOME` at a scratch copy of the real home:

```sh
cp -R ~/.aimax/buffers ~/.aimax/desktop.etf /tmp/probe-home/
AIMAX_HOME=/tmp/probe-home AIMAX_PORT=4104 AIMAX_APP_PORT=4105 \
  mix run --no-start probe.exs
```

Always probe a copy. A second daemon on `~/.aimax` writes `desktop.etf` and
clobbers the user's session.

Two known costs live on the boot path:

- **The Scheme corpus.** `Session.init/1` evaluates about 32k lines of Scheme
  synchronously (apps/aimax_core/lib/aimax/core/session.ex:457-548). There is no
  cache and no mtime check. It costs ~1.5s and every boot pays it.
- **User config shell-outs.** `load_init/1` (session.ex:575) evaluates
  `ai-config.scm` and `init.scm` from the config home. Top-level forms there can
  spawn processes: `~/.aimax/secrets.scm` makes 10 serial `doppler-secret-value`
  calls, each a blocking `shell-command->string` with a 15s limit. That is 4-7s
  when Doppler responds and up to 150s when it does not, with no log output.

Nothing else on the boot path does network I/O. MCP and LSP only register at
load; `llm_db` refreshes under a Task; the desktop restore is async and runs
after the socket opens.

Slow lane jobs do report themselves. `Aimax.Core.Lane` logs any job over 250ms
with its lane and label (apps/aimax_core/lib/aimax/core/lane.ex:166), so
`grep "slow job" ~/.aimax/daemon.log` names a stall that happens after boot.
`Session.init` runs no lane jobs of its own, so nothing inside it is timed.
