---
name: aimax-boot
description: Boot a second ai-max daemon on another port that reads the user's real config. Use whenever a task needs an extra daemon beside the running one — a scratch instance, a second workspace, a config repro, or a verify run that must load the real init.scm.
---

# Booting a second daemon on another port

One daemon owns four things: a **home** (state), a **config dir** (the user's
Scheme), an **HTTP port pair**, and a **socket**. A second daemon must take a
new home, a new port pair, and a new socket. It keeps the same config dir.

```sh
AIMAX_HOME=~/.aimax-alt AIMAX_CONFIG=~/.aimax \
AIMAX_PORT=4020 AIMAX_APP_PORT=4021 AIMAX_NAME=alt \
AIMAX_DAEMON_REGISTRY=~/.aimax-alt/daemons.json \
  nohup mix run --no-halt >> ~/.aimax-alt/daemon.log 2>&1 </dev/null &
```

Run it from the project root. `mkdir -p` the home first, because the
redirection opens the log before the daemon creates the directory.

## Why each variable is there

| Variable | What it moves | Leave it out and |
|---|---|---|
| `AIMAX_HOME` | state: `desktop.etf`, `buffers/`, `docs/`, `sock`, `peer-id`, `llmdb.json` | the new daemon writes the user's desktop and buffers |
| `AIMAX_CONFIG` | where user Scheme reads from: `ai-config.scm`, `init.scm`, `custom.scm`, `theme.scm`, key files, `packages/` | the new daemon boots stock, with none of the user's config |
| `AIMAX_PORT` | the editor origin | the endpoint fails with `:eaddrinuse` and the whole boot aborts |
| `AIMAX_APP_PORT` | the preview-app origin | the same crash, one port later |
| `AIMAX_NAME` | the label in the extension's daemon list | it defaults to the home's basename |
| `AIMAX_DAEMON_REGISTRY` | the shared daemon list | the new daemon writes a row into the user's `~/.aimax/daemons.json` |

`AIMAX_HOME` alone moves the socket and the desktop file with it. The other
paths follow the home, so `AIMAX_SOCK` and `AIMAX_DESKTOP` are only for the
case where you want one of them somewhere else.

`config/runtime.exs` resolves all of this. Read it when a knob is missing here.

## The config file route

Every knob except `AIMAX_CONFIG` also reads from `$AIMAX_HOME/daemon.conf`,
one `key = value` per line. This survives a restart, so prefer it for a
daemon that stays around:

```sh
mkdir -p ~/.aimax-alt
cat > ~/.aimax-alt/daemon.conf <<'EOF'
port = 4020
app_port = 4021
name = alt
registry = /Users/svs/.aimax-alt/daemons.json
EOF

AIMAX_HOME=~/.aimax-alt AIMAX_CONFIG=~/.aimax \
  nohup mix run --no-halt >> ~/.aimax-alt/daemon.log 2>&1 </dev/null &
```

`AIMAX_CONFIG` is read from the environment only. The conf file has no key
for it. An environment variable wins over the file for every other key.
`AIMAX_CONF=/path/to/file` names a conf file outside the home.

## Choose the port pair, do not guess it

Other daemons already hold ports in the 4000s: the user's daemon on 4004/4005,
worktree daemons from 4204 up, `AIMAX_VERIFY` on 4104/4105. A taken port kills
the boot after the Scheme corpus loads, and the failure is only in the log.
Ask the kernel first:

```sh
for p in $(seq 4020 2 4060); do
  if ! lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -nP -iTCP:$((p+1)) -sTCP:LISTEN >/dev/null 2>&1; then
    echo "free pair: $p $((p+1))"; break
  fi
done
```

## Wait for it, then prove it

The RPC socket opens last, after `Session.init` loads the whole Scheme corpus.
An open TCP port and a live PID both prove nothing. Only `ping` does. Poll it;
never sleep a fixed number of seconds:

```sh
for i in $(seq 1 60); do
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}' \
    | nc -U ~/.aimax-alt/sock 2>/dev/null | grep -q pong && break
  sleep 1
done
```

Then check that it is the daemon you meant, and that the user's config landed:

```sh
bin/aimax --home ~/.aimax-alt state
bin/aimax --home ~/.aimax-alt eval '(list (aimax-home) (aimax-config-dir) (editor-url))'
# a command defined only in the user's init.scm proves the config ran
bin/aimax --home ~/.aimax-alt eval '(member "SOME-USER-COMMAND" (command-names))'
```

`bin/aimax --home` reads the same home for `eval`, `log`, `bridge`, `keys`,
and `state`. `mix aimax.reload --home ~/.aimax-alt FILE` reloads there.

## Stop it

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"shutdown","params":{}}' | nc -U ~/.aimax-alt/sock
```

Never `pkill -f "mix run"`. That kill takes down the user's daemon and every
worktree daemon in this tree.

## Landmines

**The registry row says 4004.** `daemons.scm` calls
`(daemon-register-current! #f)` while the Scheme corpus loads, and
`aimax_ui` sets the real URL later. So the row the daemon writes at boot
carries the default `http://localhost:4004`, whatever port it listens on.
`(editor-url)` is correct after boot; the row is not. Give the daemon its own
`AIMAX_DAEMON_REGISTRY`, or accept a wrong row in the user's list. Calling
`(daemon-register-current! #f)` after boot adds a second, correct row. It does
not replace the wrong one, because the URL is the identity.

**A shared config dir is shared for writing too.** `M-x customize-save`
writes `custom.scm` and a theme change writes `theme.scm`, both into
`AIMAX_CONFIG`. Two daemons that point at `~/.aimax` overwrite each other's
saves. Copy the config dir instead when the task changes config.

**Hot reload reaches both daemons.** The watcher covers `apps/*/lib`,
`apps/aimax_core/priv`, and the config dir. One save reloads the user's daemon
and yours. This is what you want when you verify a change. It also means your
daemon is never a place to hide a broken save.

**The build is shared.** Both daemons run out of `_build/dev` in this tree.
That is normal, and it is why the second daemon boots in seconds. Give the
daemon `MIX_BUILD_PATH` and `MIX_DEPS_PATH` of its own only when it runs from
a different checkout — `Aimax.Core.Daemon` does that for worktree daemons.

**Compile errors never reach your terminal.** The daemon starts detached, so a
failed boot only appears in its `daemon.log`. Run `mix compile` first when you
suspect one: it fails in a second and leaves the running daemon alone.

## Related

- `AIMAX_VERIFY=1 mix run --no-halt` is the fixed, stock version of this: home
  `/tmp/aimax-verify-home`, ports 4104/4105, socket `/tmp/aimax-verify.sock`,
  and **no** user config. Use it to verify a change from a worktree. Use this
  skill when the task needs the user's real config.
- `aimax-restart` covers getting a change into a daemon that already runs.
- `aimax-debug` covers driving one and reading what it did.
