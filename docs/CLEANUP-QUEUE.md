# Cleanup queue

A scan of the Elixir, the Scheme, and the test suite, made on 2026-08-22.
Each item names the file, states the fault, says what it costs, and gives
the fix. The order is the order to work in.

Items marked VERIFIED were reproduced against a running editor or a test.
The rest come from reading the source.

## 1. Correctness

1. **The catalog stores effects two ways, so the permission check never
   matches half of them.** `priv/editor.scm:92` stores strings.
   `catalog-meta!` at `priv/editor.scm:134` merges the caller's raw
   symbols. `permission-effects-verdict` (`packages/agent.scm:971`) and
   the apropos effect filter (`packages/tools.scm:392`) both compare
   strings, so all 39 `catalog-meta!` entries never match. Effects decide
   permissions. Fix: run `catalog--string` over `effects` and `domain`
   inside `catalog--merge`.

2. **`permission-effects-verdict` grants allow-always on guessed
   effects.** `packages/agent.scm:971`. A tool whose effects an LLM
   guessed at 0.88 confidence is auto-allowed forever. Fix: require
   `metadata-source` to equal `"declared"` before the grant.

3. **`define-tool!` writes a duplicate effects key and the JSON emits the
   wrong one.** `packages/tools.scm:29`. The catalog tool hands the model
   `"effects":{"write":"execute"}` instead of a list. Fix: strip
   `effects`, `domain`, `namespace`, `package`, and `qualified-name` from
   `meta` before the append in `catalog-register!`.

4. **A failed `thread/start` wedges a chat at running forever.**
   `lib/aimax/core/agent/backend/codex_app_server.ex:264`. Only a
   `turn/start` error emits `turn-failed`. Fix: widen the guard to any
   errored method that holds a `pending_prompt`, and clear it.

5. **Mid-turn steering text reaches the model as Elixir inspect output.**
   `lib/aimax/core/llm.ex:566`. `to_req_msg/1` matches only tool-result
   shapes, so a steered text block goes on the wire as
   `%{"text" => ...}`. The record keeps it, so every later turn replays
   it. Fix: add a text-block clause and make the fallback an error.

6. **The permission gate sees a different string on each lane.**
   `backend/req_llm.ex:356` passes `name <> " " <> inspect(input)`, while
   ACP and Codex pass JSON. A deny pattern that matches on one backend
   misses on another. Fix: `Jason.encode!(input || %{})`.

7. **`Candidates.normalize/1` has no fallback clause and runs inside the
   Editor process.** `lib/aimax/core/candidates.ex:43`. One odd candidate
   from Scheme takes down the Editor, which loses every frame's window
   tree, local keymaps, kill ring, and faces. Fix: a terminal clause.

8. **A corrupt checkpoint reads as empty and then overwrites the good
   copy.** `lib/aimax/core/buffer.ex:894` with `buffer_store.ex:209`.
   Fix: log, rename the file to `.etf.bad`, and refuse to write a
   checkpoint for a buffer whose restore failed.

9. **Buffer never traps exits, so `terminate/2` almost never
   checkpoints.** `lib/aimax/core/buffer.ex:416`. A daemon restart loses
   up to 1500ms of edits per buffer. Fix: trap exits, or fan out
   `Buffer.checkpoint_now/1` from `Daemon.restart/0`.

10. **The RPC server interpolates a name into Scheme source.**
    `apps/aimax_rpc/lib/aimax/rpc/server.ex:186`. A quote in the name
    injects code. Fix: pass it as an argument through `call_named`.

11. **`list-row-line` applies `#f` as a procedure.**
    `priv/editor.scm:920`, and the same at `:1152` and `:879`. No mode
    declares `'render`, so reaching the branch is a crash, not a
    fallback. Fix: delete the three branches and the stale comment at
    `:692`.

12. **Keystrokes typed while a turn writes its transcript are lost.**
    VERIFIED. One run sent `gain` for `now read it again`. The chat
    rewrites the input region under the typing. Two cache tests now wait
    for the reply to avoid it, which hides it rather than fixes it.

13. **Server-initiated MCP requests get no reply.**
    `lib/aimax/core/mcp/conn.ex:316`. Anything but `ping` is dropped, so
    the server waits forever. `acp.ex:357` handles the same case with
    `-32601`. Fix: an id-bearing catch-all.

14. **LSP requests have no timeout.** `lib/aimax/core/lsp/conn.ex:517`. A
    silent server roots a Scheme closure forever. `browser.ex:200` does
    this right. Fix: a per-request timer, plus a catch-all clause in
    `dispatch/2` for a response with neither error nor result.

15. **The face CSS path escapes its own block.**
    `apps/aimax_ui/lib/aimax/ui/editor_live.ex:2057`. `vars` interpolates
    a face name unfiltered while `classes` filters it. A name containing
    `}` rewrites the whole page's CSS. Fix: apply the same filter, and
    reject values matching `[;}{<]`.

## 2. State that leaks

16. **`execute*` sets the chat mode only when the buffer takes the
    selected window.** `packages/agent.scm:1904`. A thread that opens
    elsewhere restores as inert text: no RET, no C-g, no runtime sweep.
    `execute` is a public RPC entry point. Fix: set the mode with
    `with-current-buffer`, before `display-buffer`.

17. **`group-chat` creates a chat buffer with no mode.**
    `packages/groups.scm:497`. Four callers create without showing. Same
    restore loss as above.

18. **Three modes replace `desktop-skip-locals` instead of adding to
    it.** `packages/diff-mode.scm:827`, `:971`, and
    `packages/agenda.scm:592`. The direct write wipes the entries the
    dashboard registered, so derived block trees land in `desktop.etf`.
    Fix: call `desktop-skip!`, which is additive.

19. **Four mode installs bypass `set-mode!`, so the mode hook and the
    layout engine never run.** `packages/mcp-hub.scm:296` and `:353`,
    `packages/annotate.scm:875`, `priv/editor.scm:4104`.

20. **A runtime-defined command inherits whichever package loaded last.**
    `priv/editor.scm:450`. `list-flag-D`, a generic list command, is
    catalogued today under `package morg-tangle, domain journal`. Fix:
    snapshot the scope where the command is defined.

21. **`modeline-info` and `modeline-info-command` are in none of the
    three chat-local lists.** `packages/agent.scm:1803`. `chat-queued`
    had the same fault and is now fixed.

## 3. The byte-offset rule

`string-index` and `string-rindex` return BYTES. `substring` and
`string-length` count CHARACTERS. These five pair them wrongly, so one
non-ASCII character gives a wrong answer:

22. `priv/dired.scm:319` `path-directory`. It feeds `default-directory`
    for find-file and for every shell command.
23. `priv/editor.scm:2943` `path-split` and `:2914`
    `normalize-file-input`. Every file prompt and completion.
24. `packages/project.scm:13` `parent-dir`. It walks for `.git`, so one
    non-ASCII directory gives the wrong project root.
25. `priv/dired.scm:76` `dired-vc-entry`. Git marks attach to the wrong
    row.
26. `packages/git.scm:170` `git--basename`.
27. `packages/agent.scm:304` `agent-clip` cuts UTF-8 mid-character, so a
    tool card title with a non-ASCII argument renders as mojibake. Fix:
    clip by characters.

The buffer, overlay, and fold layer is clean. No character count reaches
`goto-char`, `overlay-add!`, or `fold-add!`.

## 4. Catalog metadata, the house rule

28. **567 of 1219 catalog entries carry guessed metadata, not declared
    metadata.** `package!` resets the scope to unknown, and a file that
    never re-stamps ships everything unknown. The worst are `editor`
    (~230), `evil` (~106), `notmuch` (47, with no `effects!` in 1181
    lines), `recipes` (35), `mcp-hub` (20).

29. **`packages/agent.scm` has no metadata scope until line 1144.**
    Everything above it, including the permission commands, is guessed.
    Effects decide permissions. Stamp this file first.

30. **`packages/chat.scm:25` sets `(effects! '(read))` as a file
    default.** That is the fallback the house rules forbid, and twelve
    definitions that write inherit it, including `chat-log-save!`,
    `chat-send-region`, and `chat-compact`. The same pattern is in
    `annotate.scm:21`, `occur.scm:9`, `switch.scm:233`, and `git.scm:141`.

31. **`apropos--key` hardcodes `'("read")` for an uncatalogued command.**
    `packages/tools.scm:322`. Fix: `'("unknown")`.

32. **`catalog-meta!` never updates `metadata-source`.**
    `priv/editor.scm:134`. 63 entries report unknown while carrying
    declared values. Any reader that tells declared from guessed reads a
    lie.

33. **The Luna backfill artifact is now the stale half.** VERIFIED. The
    loader stamps package and origin per file, and matches went from 235
    to 576 of 653. The remaining misses are artifact keys for
    definitions that moved or went away: `ibuffer/*` merged into the
    switcher, `dired/dired-filter-*` became the generic list filter,
    `diff-mode/diff-mode` moved to `git/`. Re-key or regenerate
    `priv/catalog-backfill.json`, then update the two frozen counts in
    `apropos_test.exs:52`. Do not bump the counts alone.

## 5. Policy that belongs in Scheme

34. **Elixir knows what a chat and a render mode are, in six places.**
    `editor.ex:1973` reads twelve chat locals by name.
    `editor.ex:774`, `:1874`, `:2017`, `:2027`, `app_server.ex:80`, and
    `editor_live.ex:1153` each hardcode a different subset of the
    render-mode table, and two have already drifted. Fix: one
    Scheme-supplied descriptor per render mode, carried in the payload.

35. **The browser arbitrates keymap precedence.**
    `apps/aimax_ui/lib/aimax/ui/layouts.ex:856` keeps a hand-copy of
    fifteen `s-*` bindings, and `:1494` intercepts arrows and `C-n` and
    `C-p` before the key event. A new binding in Scheme cannot fire and
    nothing says why. Fix: ship both lists in `render_state`.

36. **`completion_key/2` hardcodes DEL and SPC three lines under a
    comment saying it does not.** `lib/aimax/core/key_dispatch.ex:68`.
    Fix: bind them in the completion keymap and delete the branch.

37. **Word motion and completion ranking are Elixir policy.**
    `buffer.ex:1419` treats every byte above 127 as a word character, so
    `M-f` skips whole clauses in prose. `candidates.ex:152` owns the
    match and rank strategy with no way for a prompt to supply its own.

## 6. Duplication and dead code

38. `sh-quote` is public in `priv/editor.scm:4130` and reimplemented six
    times: `notmuch.scm:63`, `doppler.scm:34`, `feeds.scm:135`,
    `web.scm:42`, `graphql.scm:121`, `sentry.scm:66`. The copies have
    already drifted on whether to quote a configurable program name.

39. Connector and model resolution has three disagreeing versions:
    `priv/editor.scm:4356`, `packages/transient.scm:450`,
    `packages/worktrees.scm:110`. For a buffer with a model and no
    connector, the menu shows one lane and the send uses another. The
    default connector is `"api"` in three places and `"claude-code"` in
    eight.

40. Dead row renderers that now contradict the live view:
    `mcp-hub.scm:92`, `notmuch.scm:139`, `agent.scm:1976`,
    `groups.scm:255`. `agents-line` and `agents-cells` order their
    columns differently, so anyone reading the dead one gets it wrong.

41. `Keys` defines `updated()` twice in one object literal:
    `apps/aimax_ui/lib/aimax/ui/layouts.ex:1288` and `:1779`. JavaScript
    discards the first, and the two bodies have drifted.

42. `editor.ex:381` writes the frame map literal twice.
    `scheme_api.ex:1037` and `:1054` are byte-identical apart from one
    wrapper. `editor_live.ex:1846` re-declares the Morg runner list from
    `packages/morg/morg-babel.scm:15`.

## 7. Errors that vanish

43. `session.ex:284` discards every `post-command!` hook failure.
44. `model_catalog.ex:29` turns any fault into an empty model picker.
45. `llmdb.ex:148` ignores a failed write, so a read-only home loses the
    billing ledger.
46. `daemon.ex:128` turns a real compile failure into success.
47. `reactor.ex:196` rescues, but `Buffer.get_local/2` fails by exit, so
    a dying buffer kills the Reactor and drops every change rule.
48. `oembed.ex:70` never clears `inflight` when its Task dies. The card
    says Loading forever.
49. `editor.ex:1838` `safe_snapshot` should log. Today a render fault is
    a blank window with no explanation.

## 8. Test suite

50. **Fixtures leak into global registries.** `mode_icon_test.exs:112`
    leaves `*marginalia-file-dir*` pointing at a deleted directory.
    `web_browse_test.exs:44` and `feeds_test.exs:46` fight over
    `*web-fetch*`. Three sentry files stub five seams and restore none.
    `list_performance_test.exs:32` and `buffer_cache_test.exs:106` leave
    the catalog scope set, which is what `apropos_test.exs:63` measures.
51. **Hooks and tools are cleaned up in the test body, not `on_exit`.**
    `editor_test.exs:239` and `:1423`, `watch_test.exs:211`,
    `on_change_test.exs`, `cache_economics_test.exs:187`. One failing
    assertion above the cleanup leaks the state for the whole partition.
52. **`custom.scm` survives between runs.** `customize_test.exs:20`
    writes it into the test home and never removes it, and boot loads
    it. Purge it in `test_helper.exs` beside `buffers/`.
53. **Chat auto-rename fires real paid requests in five test files.**
    `agent_test.exs`, `chat_agent_test.exs`, `chat_file_test.exs`,
    `chat_reset_test.exs`, `backend_stub_test.exs` set only the ACP
    transport. Fix: turn the rename off in `test_helper.exs` and let the
    files that test renaming opt back in.
54. **Two audits were narrowed to ignore `zz-` names**
    (`help_test.exs:334`, `llm_tools_test.exs:58`) so leaked fixtures
    stop failing them. The registries need a way to deregister instead.
55. **Fixed sleeps instead of polling**, worst in `on_change_test.exs`
    (eleven), `git_diff_test.exs:495` and `desktop_restore_test.exs:375`
    (1100ms each for mtime granularity), and `desktop_restore_test.exs:344`
    (four seconds of `sleep 4`).
56. **Negative assertions on short windows**: `refute_receive ..., 200`
    in `api_lane_test.exs:191` and `agent_test.exs:681`. Under a loaded
    four-partition run this proves the machine was busy, nothing more.
57. **`desktop_restore_test.exs:151` greps the Scheme source for
    `'mode-name` with a regular expression.** It cannot see a name built
    at runtime and it breaks on formatting. Assert the state instead.

## 9. Open and deliberate

58. **`markdown-mode` does not exist.** Two tests in `morg_test.exs`
    describe it and are skipped. There is no major-mode teardown in
    `set-mode!` at all, so a Morg buffer keeps its folds, its keys, and
    its overlays after the mode changes. Building it needs the mode, a
    teardown hook, a Morg teardown, and a markdown grammar.

59. **Two catalog tests fail on purpose.** See item 33. They need the
    artifact reviewed, not the counts bumped.

## 10. Working practice

60. **An in-editor agent save overwrote committed work three times
    tonight**, in `agenda.scm`, in `editor.scm`, and once more for the
    single `chat-queued` entry. The save writes the buffer as it was
    read, so any commit made in between disappears with no conflict.
    A changed-on-disk guard before save would end this whole class.
