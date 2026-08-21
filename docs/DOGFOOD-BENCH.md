# The ai-max dogfood benchmark

This is a black-box benchmark for one internal question:

> Does ai-max make real work noticeably better than using an editor, terminal,
> browser, and chat separately?

The runner lives outside ai-max. It talks only to the public JSON-RPC socket,
creates an ordinary agent thread with `execute*`, and observes that thread via
`agent-status`, `agent-buf`, and `buffer-text`. The product contains no
benchmark-specific Scheme or Elixir.

The runner automates setup, submission, observation, restart, deterministic
checks, and reporting. Trust, leverage, and “would I use this again?” remain
human judgements.

## Start an isolated editor

The default benchmark daemon uses `/tmp/aimax-bench-home`, port 4104, and app
port 4105:

```sh
bench/aimax-bench --home /tmp/aimax-bench-home daemon start \
  --config-from ~/.aimax
```

`--config-from` symlinks `ai-config.scm` and its sibling `secrets.scm` into the
isolated home; secret contents are not copied into benchmark results. Without
that option, the home needs its own provider configuration.
You can instead point the runner at an existing daemon without starting one:

```sh
bench/aimax-bench --home ~/.aimax list
```

`--socket PATH` overrides the derived `$AIMAX_HOME/sock` for unusual layouts.

## Run a scenario

List the stable scenarios:

```sh
bench/aimax-bench list
bench/aimax-bench list --cadence daily
bench/aimax-bench list --area control
```

Start a real task. `--objective` replaces the generic catalog prompt while the
scenario's setup, acceptance criteria, and hard gates remain fixed:

```sh
bench/aimax-bench --home /tmp/aimax-bench-home start small-feature \
  --objective "Add an RPC command that returns the active project root." \
  --connector api \
  --model anthropic:claude-sonnet-5 \
  --permission-mode ask \
  --presets aimax,project \
  --workspace "$PWD"
```

For a multiline request use `--objective-file PATH`. Prompts and connector
configuration are base64-encoded before being placed in Scheme expressions;
scenario text is never interpolated as executable Scheme.
`--workspace` is passed as `execute*`'s Scheme `directory` option, so the
created chat receives the real working directory as ordinary buffer-local
policy. It is not merely metadata in the run journal.

The command records the returned agent slug and an initial black-box
observation. Follow the actual thread through renames and wait for it:

```sh
bench/aimax-bench wait RUN_ID
bench/aimax-bench show RUN_ID --transcript
```

`wait` returns when the agent becomes idle, dead, or needs attention. The
editor remains the place to inspect work, answer permissions, steer, undo, and
continue manually.

## Replay a saved chat

Every completed conversation is archived under `<aimax-home>/chats/*.chat`.
The public Scheme API lists and reads those portable records:

```scheme
(chat-log-files)
(chat-log-read "/absolute/path.chat")
```

Send one archive through the editor's replay acceptance test:

```sh
AIMAX_CHAT=/absolute/path.chat mix test \
  apps/aimax_core/test/aimax/chat_acceptance_test.exs
```

The replay drives recorded prompts through the real key dispatcher.
It checks transcript fidelity, tool cards, folds, and the rebuilt record.
It does not establish that the original result was correct or satisfactory.
Corroborate the transcript with resulting buffers, files, and external state.

For the bundled synthetic code scenarios, copy a fixture into a new disposable
Git repository. The command refuses to overwrite an existing destination:

```sh
bench/aimax-bench fixture diagnose /tmp/aimax-diagnose-1
bench/aimax-bench fixture small-feature /tmp/aimax-feature-1
```

Use a fresh daemon home for each independent scenario. Reusing a home is
reserved for restart/continuity checks; otherwise restored chats can
contaminate a later run.

If setup failed before the scenario was meaningfully exercised, preserve the
journal but exclude it from satisfaction metrics:

```sh
bench/aimax-bench invalidate RUN_ID --reason "provider key was unavailable"
```

## Restart and verify

Continuity scenarios use the same isolated home:

```sh
bench/aimax-bench --home /tmp/aimax-bench-home daemon restart
bench/aimax-bench --home /tmp/aimax-bench-home show RUN_ID --transcript
bench/aimax-bench --home /tmp/aimax-bench-home continue RUN_ID \
  --objective "Continue from the durable state already present."
```

The external run journal survives independently of the daemon. The restored
editor must supply the buffer and conversation state again.

At finish time, optional `--check` expressions are evaluated through the same
RPC boundary. A Scheme false value fails a check; any other returned value
passes. Use checks for observable outcomes, not private implementation details:

```sh
bench/aimax-bench --home /tmp/aimax-bench-home finish RUN_ID \
  --outcome pass \
  --intended-state yes \
  --interventions 0 \
  --reuse 5 \
  --trust yes \
  --leverage yes \
  --check '(file-exists? "/tmp/example/output.txt")' \
  --notes "Found the right primitive and left a focused diff."
```

Only gates named by the scenario are required. `--offline` permits scoring a
run when the daemon is unavailable, recording that the final observation could
not be collected.

If later transcript review changes an operator judgement, use `rescore` with
the same score flags. It preserves the original observations and records a
`rescored_at` timestamp instead of rewriting run history.

## Read the result

```sh
bench/aimax-bench report
bench/aimax-bench report --task small-feature
bench/aimax-bench report --json
bench/aimax-bench render --output bench/results/core-suite.html
```

`render` selects the latest valid finished run for each of the six core
acceptance scenarios and writes a standalone HTML summary. Historical failures
remain in `report`; infrastructure-invalid runs remain in their journals but
are excluded from both views.

Run journals default to `~/.aimax-bench/runs`; set `AIMAX_BENCH_HOME` or pass
`--results PATH` to separate experiments.

The primary measure is zero-intervention success. A successful run reaches the
intended state, receives a `pass`, passes every deterministic `--check`, and
passes every evaluated hard gate:

- **Trust:** no silent destructive, external, or surprising action.
- **Continuity:** restart, cancellation, compaction, and interruption preserve
  the task.
- **Leverage:** the workflow is materially preferable to doing it manually.

Cost and token counts are diagnostics rather than goals. Stable scenarios and
honest operator scores matter more than leaderboard comparability.

## Test the runner

The runner uses only Python's standard library:

```sh
python3 -m unittest discover -s bench -p 'test_*.py'
```
