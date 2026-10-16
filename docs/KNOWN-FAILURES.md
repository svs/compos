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
| a-chat-title-holds-at-most-six-words | the title clip: chat.scm 165291b4 (2026-10-12) trims 'is' from the title; not caused today |
| the-header-line-carries-identity-and-the-mode-line-carries-state | the switcher test expects buffer-switcher, renamed to modeline-expand in aacfe2e6; not caused today |
| an-editing-buffer-wears-the-cua-tag | the state-tag test expects 'cua', but the code shows 'ESC' since 8b639fbd; not caused today |
| the-api-lane-adds-a-usage-fact-once-a-turn-has-billed, the-acp-lane-reports-no-usage-fact, usage-never-borrows-a-groups-other-buffers-spend, a-preset-still-carries-its-usage-fact | the four usage-fact tests call dash--usage, removed in aacfe2e6 (three raise unbound; a-preset fails its usage check); not caused today |
| a-project-file-keeps-a-project-relative-buffer-modeline-name | passes alone; the full run raises an LSP connection error (scheme-langserver); cause open; not caused today |
| unstamped-bundled-declarations-do-not-multiply, a-near-miss-on-a-name-lands-anyway, kind-package-namespace-domain-and-effect-filters-compose, components-use-the-main-catalog-and-expose-a-runnable-contract | apropos and the catalog |
| malformed-scheme-goes-nowhere, code-mode-asks-before-it-assigns-this-frame-a-worktree | code-mode |
| subagents-table-draws-one-row-per-edge, overview-uses-only-the-current-group | one each |
| every-mode-says-what-it-is-for | six modes call no mode-doc!: google-compose-mode, google-detail-mode, google-request-mode, irc-mode, special-mode, and the keymap-test-list-mode fixture; red at HEAD before the mode table (b5302dd4) |
| a-pasted-images-link-is-relative-to-the-document | the test home is not a git repository; the git rev-parse error list reaches string-append |
| the-editor-seams-are-named-hooks | buffer-created! on a name with no buffer process; red at HEAD b5302dd4 |
| a-blocks-presence-arms-its-keys, a-scheme-result-pretty-prints-nested-property-lists | one each |
| agent-excision-repairs-every-transcript-offset, agent-excision-counts-bytes-after-multibyte-text | agent-excise-range! no longer moves 'agent-saved-mark by hand (the buffer keeps the marker); the test still expects the hand-moved value; red at HEAD 4f0a0be9 in a worktree run |
| a-floating-surface-does-not-change-the-frame-group | window-config-test; left to the other agent |
| a-buffer-that-wakes-catches-up-with-its-file | autorevert; red alone at HEAD 22ba6cd2 in a worktree run: the woken buffer keeps its old text |
| a-written-chat-keeps-the-written-directory | the chat-writes-chat-files rule refuses the .txt the test writes; red at HEAD a2bd2538 |
| the-companion-chat-opens-into-the-documents-group | red alone at HEAD 3ffe7c4a in a worktree run |
| a-kill-after-a-kill-appends-and-last-command-names-the-kill | kernel: last-command is next-line after kill-word, so kill-word is not recorded as the last command (last-command builtin scheme_api.ex:2725; kill check editor.scm:636); kill appending from a86ad804 (2026-09-02); not caused today |
| a-command-enters-the-editing-state-and-keyboard-quit-leaves-it | kernel: a landing that comes back is still in the editing state (expected #f, got #t); landing check editing--check-landing! (editor.scm:5135) from 1770e36a (2026-09-04); not caused today |
| a-session-event-is-kept-with-the-conversation | a reset does not clear the session event with the conversation (expected #t, got #f); agent.scm last changed 2fa47cf5 |
| semantic-results-join-the-catalog-and-keep-filters | the semantic search declares read and external but not spend (API cost); apropos-test.scm last changed 50ca5373 |
| the-done-when-one-hello-one-apropos-the-right-expression | a recipe rides the apropos search (expected #f, got #t); the search path is not pinned to one commit; not confirmed caused today |
| a-bang-input-is-prose-for-fast-code | in the focused run fast-code names are unbound (fast-accept, fast-chat-resolve, fast-palette-rows), so chat-fast-input? (agent-session.scm:364, b158e827) answers #f; fast-code.scm last changed 9b0cc4ad (2026-09-24); the loader path that leaves fast-code unloaded is not pinned; not confirmed caused today |
| a-bang-run-is-told-to-the-agent | same cause as a-bang-input: fast-chat-resolve is unbound in the focused run, so the bang never resolves; fast-code.scm last changed 9b0cc4ad (2026-09-24); not confirmed caused today |
| a-bang-completes-over-every-recipe | raises car in Builtins.entries/0 on an empty list: a hit was expected and none came back. With fast-chat-capf unbound, chat-scheme--capf (agent-session.scm:508) returns no candidates, and (car '()) raises; same cause as the bang rows; not a malformed catalog entry (the live catalog has 3840 entries, none a non-pair); not confirmed caused today |
| agent-discovery-hides-display-effects-until-presentation-is-explicit | default agent discovery shows display effects (expected #f, got #t); code-mode-test.scm last changed e65a25fe |
| an-answer-must-read-and-name-nothing-unbound | fast-accept is unbound; dbd43ee3 changed it last; fast-code.scm last changed c4145124 |
| a-function-takes-the-requests-values-as-parameters | fast-accept is unbound; dbd43ee3 changed it last; fast-code.scm last changed c4145124 |
| a-function-is-kept-once-its-call-runs-clean | fast-accept is unbound; dbd43ee3 changed it last; fast-code.scm last changed c4145124 |
| a-bang-resolves-to-a-frame-call-or-an-error | fast-chat-resolve is unbound; 9b0cc4ad changed it last; fast-code.scm last changed c4145124 |
| the-palette-hands-a-sentence-to-fast-code | fast-palette-rows is unbound; 9b0cc4ad changed it last; fast-code.scm last changed c4145124 |
| interactive-find-file-joins-the-current-group (was interactive-find-file-groups-only-a-new-buffer) | rewritten to the 2026-09-22 ruling (buffer-opens-in-current-group): a reopened buffer joins the current group; passes in the focused run |
| the-recipes-a-package-declares-reach-the-recipe-book | a graphql recipe rides the search (expected not, got a recipe/function/command list); the search path is not pinned to one commit; graphql.scm last changed 251636ee; not confirmed caused today |
| the-buffer-prompt-lists-the-pool-flat-with-the-buffer-you-are-on-last | fixed 2026-10-17, passes: switch-prompt-rows dropped the current buffer when it was live and preview-opened (the filter in switch.scm, added by 00b284e7, 2026-10-16). The filter now keeps the buffer you are on, listed last |
| the-buffer-prompt-is-the-plain-minibuffer-list | fixed 2026-10-17, passes: the same switch.scm filter as the pool-flat row (00b284e7). The test reads the All tab through ibp-open-plain! |
| typing-narrows-the-plain-prompt-and-previews-the-selection | passes in the focused run after the All-tab read (ibp-open-plain!); the earlier history-loss note was wrong |
| confirm-takes-the-row-and-brings-it-here | the row is not the current buffer and the buffer does not join the group; the ibuffer Group tab hides other groups' buffers; ibuffer.scm last changed 7a6abfe5 |
| an-open-shows-the-first-page-again | passes in the focused run; full-run order pollution (one page on the open: expected 50, got 100); list-page-test.scm last changed 97645579 |
| notmuch-starts-at-the-mailboxes-and-a-row-opens-its-search | the mailbox row's query is tag:"important", not tag:inbox; notmuch.scm last changed 781170ae |
| typing-a-form-end-to-end-keeps-the-text-balanced | passes in the focused run; full-run order pollution (point ends past the closer, expected 5, got 4); paredit.scm last changed cfd2b97e |
| the-mcp-proxy-refuses-deny-listed-payloads | the test calls mail-send, now unbound (mail-send! exists); the refusal never runs; permission-test.scm last changed f82cbe98 |
| direct-and-acp-agents-share-the-same-standing-guidance | the quiet-editor, discovery and repository guidance is not compact (expected true, got #f); prompts.scm cd9259ad and aacfe2e6 (removed general.md) are the nearest prompt changes; cause not pinned; not confirmed caused today |
| chat-show-prompt-shows-the-direct-prompt-and-its-composition | the page names no general section: aacfe2e6 removed general.md; prompt-test.scm last changed aa2f39cf |
| find-def-reaches-the-bundled-source-and-every-catalogued-package | scheme-ide--find-def answers #f (a miss where a hit was expected) for paredit-in-scheme-mode, so cadr of #f raises in Builtins.entries/0; scheme-ide--sources scans apps/compos_core/priv/packages, which is empty (packages moved to scheme/packages by 52dd7acf, 2026-09-18); not caused today |
| narrowing-to-a-dormant-candidate-wakes-it-and-leaving-sleeps-it | passes in the focused run; full-run order pollution (leaving does not sleep the candidate); switcher-sleep-test.scm last changed 97645579 |
| visiting-keeps-the-pick-awake-and-sleeps-the-other-woken-candidate | passes in the focused run; full-run order pollution (the other woken candidate stays awake); switcher-sleep-test.scm last changed 97645579 |
| telemetry-toggle-opens-the-list-and-closes-it | the same command does not close the list, and the buffer back is *Telemetry*, not *scratch*; telemetry.scm last changed b158e827 |

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
