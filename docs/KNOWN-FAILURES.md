# Known failing tests

`bin/test-fast` on a clean worktree does not come back green. This is the
record of what was already red, so the next person can tell a regression
from the weather.

Measured over **10 full runs** of `bin/test-fast` in clean worktrees at
HEAD, 2026-08-23/24, during the Scheme test migration. Counts are how many
of those 10 runs each test failed in.

**This is evidence, not permission.** A test listed here is not "allowed to
fail" — most of these are real defects nobody has looked at. Two were
confirmed this week by porting them to Scheme and watching them fail the
same way:

- `marked switcher buffers pull as one operation` — marks two rows, runs
  the pull, and neither buffer joins the group.
- `the switcher narrows by the annotation the marginalia supplies` — the
  modal switcher does not narrow.

## How to use it

Run `bin/test-fast` in a worktree at HEAD, not in the shared checkout —
another session's uncommitted work adds failures that are not yours:

```sh
git worktree add /tmp/verify HEAD && cd /tmp/verify
bin/test-fast 2>&1 | tee /tmp/run.log
grep -E "^\s+[0-9]+\) test" /tmp/run.log | sed 's/^ *[0-9]*) //' | sort > /tmp/now.txt
comm -13 <(grep -oE '^\| `[^`]+`' docs/KNOWN-FAILURES.md | tr -d '|` ') /tmp/now.txt
```

A name that is NOT in this list is the one to look at. Then, before
blaming your change: run that file alone across three seeds, and run the
same file at the commit before your change. Three of the four scares
during the migration were pre-existing, and one — `pull adds the current
group` — failed twice at HEAD and looked conclusive until it failed at the
parent commit too.

## The shape of it

The 64 names split cleanly in two, and the split is the useful part:

- **24 fail in all 10 runs.** These are not flake. They are defects with a
  reproducer already written, sitting untouched — fourteen of them in the
  switcher and the buffer list alone (`EditorTest`, `SwitcherSleepTest`,
  `SwitchModalTest`, `MarginaliaProjectTest`). If anything here is worth a
  morning, it is that cluster: one cause probably accounts for most of it.
- **21 fail in exactly 1 of 10.** Timing, ordering, frame geometry. These
  are the ones that make a green run impossible and make attribution cost
  a baseline run every time.

The rest sit in between and are worth suspecting individually.

## The count band

Whole-suite failures ranged **30-42** across the 10 runs. The count
moves on its own; so do the names. Roughly a third of this list appears in
one run and not the next. Diff the NAMES, never the number.

## The list

| count | test |
|---|---|
| 10/10 | `test C-h b lists local bindings before global ones (Aimax.HelpTest)` |
| 10/10 | `test C-k kills the dormant buffer the row names (Aimax.SwitcherSleepTest)` |
| 10/10 | `test C-x b is history first: previous buffer defaults, containers ride under it (Aimax.EditorTest)` |
| 10/10 | `test C-x p s opens the project's scratch, tags the project's buffers, and toggles back (Aimax.ProjectScratchTest)` |
| 10/10 | `test RET copies only the current secret value (Aimax.DopplerTest)` |
| 10/10 | `test RET on a name that matches nothing founds a group from the windows (Aimax.EditorTest)` |
| 10/10 | `test a group you switched to is a history row; its name finds it and its members (Aimax.EditorTest)` |
| 10/10 | `test a killed file member comes back with content, not an empty shell (Aimax.EditorTest)` |
| 10/10 | `test a project-rooted group offers its files, and the card defaults to dired (Aimax.SwitchModalTest)` |
| 10/10 | `test a row for a buffer killed elsewhere leaves the list on the next command (Aimax.SwitcherSleepTest)` |
| 10/10 | `test a stale off-screen buffer catches up when the switcher shows it (Aimax.EditorTest)` |
| 10/10 | `test a verb acts on the nearest row when point sits in the chrome (Aimax.SwitcherSleepTest)` |
| 10/10 | `test api -> codex -> claude-code -> api on ONE chat: everything survives (Aimax.SwitchTest)` |
| 10/10 | `test buffer groups: C-c g tags members, C-c q talks to the group's one chat (Aimax.EditorTest)` |
| 10/10 | `test dired (pure Scheme userland) / matches the marginalia too, and C-g puts the listing back (Aimax.EditorTest)` |
| 10/10 | `test marginalia the switcher narrows by the annotation the marginalia supplies (Aimax.MarginaliaProjectTest)` |
| 10/10 | `test mouse rows select and action controls run the keyboard commands (Aimax.DopplerTest)` |
| 10/10 | `test narrowing to a dormant candidate wakes it; ESC puts it back to sleep (Aimax.SwitcherSleepTest)` |
| 10/10 | `test opens as a grouped primary buffer, never a popup (Aimax.DopplerTest)` |
| 10/10 | `test returning from a page C-x b is the editor's own command, redefined rather than rebound (Aimax.ChromeTest)` |
| 10/10 | `test the modal switcher C-t puts the marked buffers in a group, and an empty answer removes it (Aimax.EditorTest)` |
| 10/10 | `test the modal switcher lists with the buffer annotation, narrows by mode, C-k kills, RET visits (Aimax.EditorTest)` |
| 10/10 | `test the modal switcher typing and the arrows preview the highlighted buffer in the home window (Aimax.EditorTest)` |
| 10/10 | `test which-key panel appears for pending prefix (Aimax.EditorTest)` |
| 9/10 | `test C-c s opens a plain scratch beside any ordinary buffer and toggles back (Aimax.ScratchTest)` |
| 9/10 | `test RET opens distinct grouped detail buffers through the real key path (Aimax.SentryTest)` |
| 9/10 | `test a save reloads every running app (Aimax.AppPreviewTest)` |
| 8/10 | `test C-c s opens a scratch chat that carries the coding presets (Aimax.CodeModeTest)` |
| 8/10 | `test M-x code-mode joins a group, loads the coding presets, and turns on llm-mode (Aimax.CodeModeTest)` |
| 8/10 | `test marked switcher buffers pull as one operation (Aimax.GroupSwitchCommandTest)` |
| 8/10 | `test restore-minor-modes! re-runs setup idempotently (reload path) (Aimax.CodeModeTest)` |
| 7/10 | `test C-c RET talks to the companion without leaving the document (Aimax.EditorTest)` |
| 7/10 | `test C-c w opens the optional companion for the writing workspace (Aimax.WritingTest)` |
| 7/10 | `test code-mode asks before it assigns this frame a worktree, group, and chat (Aimax.CodeModeTest)` |
| 7/10 | `test enabling writing mode opens its grouped plain scratch beside the preview (Aimax.WritingTest)` |
| 5/10 | `test M-. in a help page opens the source of the name at point (Aimax.HelpTest)` |
| 5/10 | `test a name in a help page is a link to its source, and the link opens it (Aimax.HelpTest)` |
| 5/10 | `test pull adds the current group without switching context (Aimax.GroupSwitchCommandTest)` |
| 4/10 | `test C-c q founds a group and asks its one chat from the minibuffer (Aimax.EditorTest)` |
| 4/10 | `test openai models run the tool loop like every other model (Aimax.EditorTest)` |
| 3/10 | `test chat opens the group companion; RET sends, reply appends (Aimax.EditorTest)` |
| 3/10 | `test the scroll keys move an html preview page instead of point (Aimax.HelpTest)` |
| 2/10 | `test M-? with no name at point still shows the buffer, its mode and its keys (Aimax.HelpTest)` |
| 1/10 | `test *agents* fleet: sorted by attention, y answers the current line's thread (Aimax.AgentTest)` |
| 1/10 | `test C-c C-v toggles the source of a generated page, C-h m describes a plain buffer (Aimax.HelpTest)` |
| 1/10 | `test C-g cancels every queued turn and finalizes running tool cards (Aimax.AgentTest)` |
| 1/10 | `test C-h a searches the editor and renders the hits as a page (Aimax.HelpTest)` |
| 1/10 | `test C-h k over an unbound key says so, and the capture ends (Aimax.HelpTest)` |
| 1/10 | `test M-? describes a public function at point by its signature (Aimax.HelpTest)` |
| 1/10 | `test M-? over a name the editor does not know falls back to the apropos hits (Aimax.HelpTest)` |
| 1/10 | `test M-? over prose says nothing about it and describes the buffer instead (Aimax.HelpTest)` |
| 1/10 | `test a heading takes no selection and no count (Aimax.GroupSwitchCommandTest)` |
| 1/10 | `test cancelled group creation changes no group state (Aimax.GroupSwitchCommandTest)` |
| 1/10 | `test m marks; a verb acts on every marked chat, not the line at point (Aimax.AgentTest)` |
| 1/10 | `test outbound — Scheme addresses a tab a message to a tab goes out as an overlay op (Aimax.ChromeTest)` |
| 1/10 | `test pop removes only the current group and replaces a visible buffer (Aimax.GroupSwitchCommandTest)` |
| 1/10 | `test project-ripgrep RET on the first match opens that file at that line (Aimax.ProjectSearchTest)` |
| 1/10 | `test returning from a page a buffer already on screen is selected, not pulled somewhere else (Aimax.ChromeTest)` |
| 1/10 | `test session/new carries our mcpServers and _meta; the adapter loads no user config (Aimax.AgentTest)` |
| 1/10 | `test the activity row shows work in progress and clears at turn end (Aimax.Ui.EditorLiveTest)` |
| 1/10 | `test the catalog new bundled declarations cannot silently expand the Luna backfill (Aimax.AproposTest)` |
| 1/10 | `test the catalog the bundled backfill leaves no unknown metadata (Aimax.AproposTest)` |
| 1/10 | `test the locals partition (W8) a restored chat sheds its dead runtime state; a live one keeps it (Aimax.ChatResetTest)` |
| 1/10 | `test the mode setup rebuilds the buffer from its locals (Aimax.GitDiffTest)` |
