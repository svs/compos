---
name: acceptance-testing
description: Run or revise ai-max acceptance and dogfood scenarios for internal satisfaction. Use for benchmark runs, scoring, reports, and scenario design.
---

# Acceptance-test ai-max

Measure whether ai-max makes real work better for its user.
Optimize for internal confidence, not leaderboard comparison.

Read `docs/DOGFOOD-BENCH.md` before operating or changing the harness.
Read the selected entry in `bench/scenarios.json` before starting a run.

## Keep the test black-box

Drive the product through `bench/aimax-bench` and ai-max's public RPC boundary.
Do not add benchmark-specific behavior to Scheme, Elixir, prompts, or tools.
Do not inject this skill or scoring details into the agent under test.
Do not reveal hidden checks or implementation hints in the task objective.

Use an isolated daemon home for each independent run.
Reuse one home only when the scenario tests continuity across a restart.
Use `--config-from ~/.aimax` when the isolated daemon needs the user's provider configuration.

Verify editor behavior from within ai-max.
Use buffers, locals, overlays, render state, components, and key dispatch.
Do not use Chrome or external browser automation as the ai-max verification surface.

## Run a scenario

1. Select the smallest stable scenario that covers the risk.
2. Prepare its setup exactly and record the initial state.
3. Start one run with the ordinary scenario prompt or a realistic objective.
4. Observe the real task until it becomes idle, fails, or requests attention.
5. Avoid steering unless the scenario requires an operator response.
6. Record every intervention and permission response accurately.
7. Evaluate observable outcomes and required gates.
8. Finish the run, preserve its journal, and render the report when useful.

Do not declare success because the transcript sounds convincing.
Inspect the resulting buffers, files, state, and command behavior.
Use deterministic `--check` expressions for stable observable facts.
Keep implementation details out of checks unless the requirement names them.

Mark a run invalid only when infrastructure prevents a meaningful exercise.
Do not invalidate a genuine product or agent failure.
Do not erase or replace a failed journal with a cleaner rerun.

## Use saved chats

ai-max archives completed conversations under `<aimax-home>/chats/*.chat`.
Use `(chat-log-files)` through RPC to list the current daemon's archives.
Use `(chat-log-read PATH)` to read prompts, display turns, headers, and tool records.
Prefer this structured record over Codex session files or rendered transcript scraping.

Replay one archive through the real editor and key path with:

```sh
AIMAX_CHAT=/absolute/path.chat mix test \
  apps/aimax_core/test/aimax/chat_acceptance_test.exs
```

Replay acceptance checks transport, rendering, tool cards, and conversation fidelity.
It does not prove that the original answer was correct or useful.
Review real outcomes and artifacts separately before scoring satisfaction.
Keep retrospective chat reviews separate from fresh zero-intervention scenario metrics.

## Score for satisfaction

Treat zero-intervention success as the primary result.
Score the required gates honestly:

- `trust`: The task avoids silent, destructive, external, or surprising action.
- `continuity`: Restart or interruption preserves confirmed work and context.
- `leverage`: The workflow is materially better than doing the task manually.

Use token counts, duration, and cost as diagnostics.
Do not optimize the suite for those numbers.
Record concise notes that explain failures, interventions, and operator judgment.

## Revise the suite

Add or change a scenario only for a repeated workflow, regression, or missing risk.
Write success criteria as observable user outcomes.
Keep setup deterministic and independent of an earlier run.
Name only capabilities that a normal user would reasonably know.
Require discovery when discovery is part of the behavior under test.

Prefer one focused scenario over several variations of the same happy path.
Preserve stable scenario IDs after results exist.
Increment the catalog version when the scenario contract changes.
Update runner tests and `docs/DOGFOOD-BENCH.md` when their contracts change.

Run `python3 -m unittest discover -s bench -p 'test_*.py'` after harness changes.
Inspect the generated HTML inside ai-max when report rendering changes.

## Completion gate

For a test run, report the run ID, outcome, interventions, checks, gates, and evidence location.
For a harness change, inspect the diff and run the focused runner tests.
State any product failures without softening them into infrastructure problems.
