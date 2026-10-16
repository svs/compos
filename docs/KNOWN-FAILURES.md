# Known failing tests

The tests that were red before the simplification work of 2026-09-18 and
2026-09-19, so a regression can be told from the weather. Each entry was
measured the same way: the test file as it stood before the change was run
against the code as it stood before the change, in the test env, and it
failed the same way after.

**This is evidence, not permission.** A test listed here is a defect nobody
has looked at, or a test that asserts a production key binding, which the
house rule forbids. Fix the defect or rewrite the test; do not extend the
list to make a run green.

## Elixir

| File | Red | Note |
|---|---|---|
| agent_test.exs | 37 of 52 (37 at e6e388af) | the `a1` slug and the fake-transport handshake; every ACP scenario after the first fails on `Agent.info("a1")` |
| chat_reset_test.exs, switch_test.exs, preset_test.exs | 17 | the transport never opens; same root as agent_test |
| backend_stub_test.exs | 2 | same root |
| cache_economics_test.exs | 4 of 8 | the system prompt no longer names the other group buffers, the frozen tool list, the cancelled-turn ledger row; red at HEAD ba6d2c45 |
| permission_test.exs | 6 of 8 | same root: the `a1` chat never gets its agent, so every lane test stops at agent-prompt!; red at HEAD e08f34d4 |
| chat_agent_test.exs | 3 | same root; at e6e388af the three are "a failed inline turn says why and clears its pending send", "api threads pin a per-chat model and take a switch in place", "execute* gives a spawned chat an explicit working directory" |
| git_test.exs | 1 | "diff of a binary file reports binary? and no hunks"; red at 6ad021f0 |
| listing_window_test.exs "the chat picker previews in a card and leaves the invoking pane alone"; ibuffer-prompt-test.scm "the-prompt-previews-in-a-card-like-the-window-form", "typing-narrows-the-table-and-arrows-move-its-highlight" | 3 | red with the in-editor agent's preview and card work (the commit "the in-editor agent's work, merged onto HEAD"); green at 917c629a |
| db_test.exs | 1 | "with PostgreSQL a transaction handle cannot escape its procedure": the error now says "transaction belongs to another execution lane", not "no longer active"; red at e6e388af |
| transient_test.exs | 2 | the LLM menu no longer applies a saved combination |
| project_search_test.exs | 4 | group membership after project-switch and dired-in-group; the ripgrep hint carries an `M-1` prefix |
| llm_tools_test.exs | 3 | apropos output format; describe-function source; 22 tools where the test expects 10 (the tool zoo regrew, audit item 5.6) |
| write_file_test.exs | 1 | `C-n then RET` in the write prompt leaves the minibuffer |
| movie_test.exs, chosen_pane_test.exs, spotify_test.exs | 1 each | opt-in apps |
| chrome_test.exs | 1 | "returning from a page a buffer already on screen is selected" |
| load_test.exs | 0 | was red on calendar.scm, which init.scm never loaded; now expected |
| compos_ui, 15 of 300 (preview_cursor 1, peek_card 2, app_server 1 (spreadsheet-open! unbound), agent_view 3, dismiss 2, composml_list 1, island 1, buffer_link 1, composml_text_list 1, editor_live 2 (the modeline name and minor-mode clicks)) | 15 | the same 15 names at 47735078 in a worktree with its own build, before the live-dashboard removal of 2026-09-19; sentry--apply-detail! unbound in two of them |
| compos_ui agent_view_test.exs | 3 of 13 | the verbosity control, the text-scale rule and the modeline name markup; red at HEAD 53f4b07b |
| desktop_session_restart_test.exs | 1 | "every live buffer gets its Scheme runtime rebuilt, not only the visible ones": one Session death recovered 2 times; red 3 of 3 alone at HEAD 22ba6cd2 in a worktree with its own build |
| listing_window_test.exs | 2 | "ibuffer opens here with an inert card and retains the listing on quit", "ichat opens here ..."; red at 243fc29b in a worktree with its own build |
| chat_peek_render_test.exs | 1 | "peek enables an arbitrary source mode and preserves its rich projection"; red at 243fc29b |
| spreadsheet_mode_test.exs | 1 | "running spreadsheet mode on the JSON source does not replace its data": the JSON buffer is pretty-printed; red at 243fc29b |
| compos_ui composml_text_list_test.exs | 0 to 1 | "ibuffer owns semantic records while retaining its text lines and navigation": `list-refresh!` of *ibuffer* raises substring-bytes on an empty buffer, 2 of 9 runs after step 4 and 0 of 7 at 243fc29b; no step 4 change touches the list path; intermittent |
| desktop_restore_test.exs | 2 | "every literal mode-name write names a registered mode": ibuffer-test.scm writes `aa-other-mode` (d293b2d9) and no define-mode registers it; "LLM configuration history survives desktop restore": the history rows are plists now, the test expects bare lists |

## Scheme (priv/tests and the package tests)

Run one kernel file with `SCHEME_TESTS=name mix test apps/compos_core/test/compos/scheme_suite_test.exs`,
and one package's tests with `SCHEME_TESTS=name mix test --include packages apps/compos_core/test/compos/package_suite_test.exs`.
Since 2026-09-19 the package tests live beside their packages (scheme/packages/NAME-test.scm).
In the full package run, 20 layout-policy names, 4 notmuch names and one each in web-browse and
writing go red by order only; each passes when its file runs alone (see "Tests live with their packages" in SIMPLIFY-AUDIT.md).

| Test | Note |
|---|---|
| a-minor-mode-map-answers-ahead..., every-major-mode-key-leads-to-a-live-command, a-list-mode-answers-to-its-own-map-under-list-mode-map | the keymap ladder |
| list-group-and-sort-keys-run-the-declared-cycles | the keymap ladder; the list mode's reserved group key still answers list-filter; red at 10609f4f before the buffer-kill! keymap fix (same text in km-head.log, before the keymap port) |
| fence-markers-step-back-with-other-preview-markup, a-link-keeps-its-text-and-hides-its-target, a-csv-block-draws-as-a-table | blocks |
| the-default-face-size-is-the-setting-and-survives-a-theme, a-dark-theme-shows-the-row-under-point | themes; red since the warm-dark theme commit |
| the-stance-is-set-in-one-place, the-modeline-names-the-tool-surface | llm-setup-test; 41ffa950 clears 'modeline-info |
| unstamped-bundled-declarations-do-not-multiply, a-near-miss-on-a-name-lands-anyway, kind-package-namespace-domain-and-effect-filters-compose, components-use-the-main-catalog-and-expose-a-runnable-contract | apropos and the catalog |
| malformed-scheme-goes-nowhere, code-mode-asks-before-it-assigns-this-frame-a-worktree | code-mode |
| the-index-gives-each-thread-two-lines, every-tag-reads-in-full-until-the-column-narrows, notmuch-quit-kills-the-mail-views-and-lands-on-work, mark-all-then-archive-marked-asks-before-it-acts | notmuch |
| subagents-table-draws-one-row-per-edge, overview-uses-only-the-current-group | one each |
| every-mode-says-what-it-is-for | six modes call no mode-doc!: google-compose-mode, google-detail-mode, google-request-mode, irc-mode, special-mode, and the keymap-test-list-mode fixture; red at HEAD before the mode table (b5302dd4) |
| a-pasted-images-link-is-relative-to-the-document | the test home is not a git repository; the git rev-parse error list reaches string-append |
| the-editor-seams-are-named-hooks | buffer-created! on a name with no buffer process; red at HEAD b5302dd4 |
| ibuffer-act-reads-the-marks, ibuffer-sections-by-mode, ibuffer-toggle-mark-marks-then-unmarks, ibuffer-visit-enters-the-group-of-the-row, ibuffer-visit-stays-put-for-a-buffer-of-this-group | ibuffer and its prompt; red at HEAD b5302dd4 in a worktree run, while the listing preview (fc980588) is under work in another session |
| a-blocks-presence-arms-its-keys, a-scheme-result-pretty-prints-nested-property-lists | one each |
| a-refresh-keeps-a-non-selected-window-on-its-row, an-agents-edit-keeps-a-peeked-file, overview-locks-the-frame-and-quit-restores, three-columns-outside-a-group-fill-from-the-buffer-mru | layouts and target layouts, red at HEAD 73c34f57 in a worktree run while the other session works on layouts. Bisected 2026-09-19: layout-policy 8 red at 66d2ea54 (its own last commit's day), group-switch 2 red at 66d2ea54 and 5 at 8f859bba (the agent commit that moved category foreign from the popup to the window chain), 6 at f6ad9f51, 9 at 0a3bfa57; detail 2 red at b5123dce and the third only behind them. None went red under the simplification; make-frame! (two names) is restored. The group-switch and layout-policy names left this row on 2026-09-19: the tests state the code now (docs/SIMPLIFY-AUDIT.md section 10, "Phase 2 gate, closed by ruling") |
| agent-excision-repairs-every-transcript-offset, agent-excision-counts-bytes-after-multibyte-text | agent-excise-range! no longer moves 'agent-saved-mark by hand (the buffer keeps the marker); the test still expects the hand-moved value; red at HEAD 4f0a0be9 in a worktree run |
| relayout-preserves-pane-order-and-focus, a-target-layout-does-not-give-one-mode-two-panes, fixed-target-fills-vacancies-then-replaces-the-selected-slot, smaller-target-keeps-focus-and-the-first-surviving-slots, passive-results-replace-the-oldest-other-pane-and-quit-restores-it, selected-result-quit-restores-the-buffer-under-it, a-full-layout-does-not-grow-a-pane-for-new-work, a-group-chat-joins-the-frame-instead-of-collapsing-it, a-group-chat-arranges-by-the-frames-chosen-layout, a-floating-surface-does-not-change-the-frame-group | red only when the six layout files run in one lane (SCHEME_TESTS=layout-policy,group-switch,window-config,detail,ibuffer); each passes with its file alone: order pollution. Since 2026-09-19 group-switch, layout-policy, detail and ibuffer-prompt pass in one lane: the detached reflow task was the race. The six-file lane is not measured again |
| a-buffer-that-wakes-catches-up-with-its-file | autorevert; red alone at HEAD 22ba6cd2 in a worktree run: the woken buffer keeps its old text |
| a-written-chat-keeps-the-written-directory | the chat-writes-chat-files rule refuses the .txt the test writes; red at HEAD a2bd2538 |
| the-companion-chat-opens-into-the-documents-group | red alone at HEAD 3ffe7c4a in a worktree run |
| disabling-writing-mode-restores-the-previous-look | passes with a clean test home; llm_tools_test.exs saves `(org-font-family "ToolFont")` into the test home custom.scm and leaves it, and org then opens in ToolFont |
| a-page-opens-in-the-frame-group-when-the-window-has-none-and-cycles-views | passes alone; fails when the feeds tests run first (test pollution) |
| membership-answers-the-id, llm-config-session-is-the-groups-most-recent-chat, a-summary-is-always-a-string, applying-a-bundle-applies-all-of-it, a-bundle-remembers-disabled-prompt-sections | pass alone; fail after other files leave a group behind (test pollution) |

## A store moved by a kernel reload

When a kernel section moves its state from one global to another (the
keyed hooks moved from `*keyed-hooks*` to the registry table `(hook HOOK)`
on 2026-10-16), a hot reload of editor.scm into a running daemon leaves
the old global full and the new readers empty: every listener is silent
until the entries are moved, and no test sees it, since a fresh test
daemon never held the old store. Ship a one-shot carry-over beside the
new readers, as `hook--carry-keyed!` does: move the entries when the old
global is bound and non-empty, then empty it. docs/HOOKS.md has the rule.

## Faster ways to ask

`mix test --failed` reruns what failed last time (`_build/test/lib/<app>/.mix/.mix_test_failures`).
`SCHEME_TIMES=1` on the Scheme bridge prints the slowest tests.
To attribute a failure: run the pre-change test file (`git show HEAD:path > test/compos/zz_old_x_test.exs`,
with the module renamed) against the pre-change code, and compare failure names, not counts.
