# Packages - three tiers of repos

Status: proposal, 2026-11-15. On 2026-11-18 the standard tier moved back into this repo as `scheme/stdlib`; `compos-dev/compos-packages` keeps its history before that. The assignment table is a first cut. A dependency check must confirm it before any file moves.

## The tiers

| Tier | Repo | Count | Installed | Who owns it |
|---|---|---|---|---|
| 1. Core | `compos` (this repo) | one | always, cannot be removed. Only what boot needs | the compos team |
| 2. Standard | `compos`, in `scheme/stdlib` | one directory per package | on by default, the user can turn each one off. Quality of life: chat, todo, git, code | the compos team, PRs welcome |
| 3. Community | one repo per package, anywhere on GitHub | unlimited | only when the user asks. Mail, linear, apps, services | the package author |
| 4. Personal | none: `~/.compos/packages` and each folder `init.scm` puts on `load-path` | any | only what `init.scm` names. Never pushed | the user |

## Rules

1. Core holds only what boot needs: start, draw a frame, open, edit and save a file, run M-x, set a variable, install packages. The core test suite passes with an empty package list.
2. Core never requires a package. A package can require core. A standard package can require other standard packages. A community package can require any package that has a recipe.
3. Core publishes the API. The public catalog (apropos with the domain and effects stamps) is the contract. Core keeps a version number for that contract, `compos-api-version`.
4. Each package declares the lowest `compos-api-version` it works with. The package manager refuses a package that needs a newer core.
5. A package keeps its tests beside it: `NAME/NAME-test.scm`. The tests move with the package.
6. A release bundles core and the standard packages at pinned commits. The first boot works offline.
7. Dev-only packages (eval harnesses, demos, profilers) stay in the core repo under `scheme/dev/`. A release does not load them.

## Repo layouts

### 1. Core: `compos`

The Elixir apps, `priv/editor.scm`, and `scheme/core/`. `scheme/packages/` and `scheme/apps/` go away.

### 2. Standard: `scheme/stdlib`

```
scheme/stdlib/
  stdlib.scm             ; puts each package directory on load-path, loads the stock set
  recipes.scm            ; one recipe for every standard package
  chat-mode/chat-mode.scm
  todo/todo.scm
  ...
```

anchor and app-registry are standard: every app uses them, and core's lists and components call anchor only once the editor is up.

One directory for each package, in the core repo, so one change can touch core and stdlib together. A Scheme name lives at one level: `stdlib_levels_test.exs` fails on a file name or top-level define in both `scheme/packages` and `scheme/stdlib`.

### 3. Community: one repo each

```
compos-spotify/
  recipe.scm             ; (spotify :requires (http components) :api 3)
  spotify.scm
  spotify-test.scm
```

A community package gets into the `M-x packages` list when its recipe is in `compos-packages/index.scm`. A PR to that file adds it. A user can also install by URL without the index.

### 4. Personal: the user's own files

```
~/.compos/packages/
  travel.scm             ; code only: the trips are in ~/.compos/travel
  travel/google-hotels.xsl
  other-buffer.scm
```

This is `~/.emacs.d/lisp` for compos: single files on this machine, with no recipe, no lock and no remote. The folders are `(personal-package-dirs)`: `(package-dir)` first, then each `load-path` folder outside the compos checkout and the clones. `init.scm` loads them in order with one call, `(personal-packages! 'other-buffer 'travel)`, which stamps each as the user's. `(personal-file REL)` finds a file such as a stylesheet in those folders. `M-x packages` lists every file there under the Personal tab and marks the loaded ones.

A package of any tier keeps its data out of the code folders, in `(package-data-dir NAME)`, which is `~/.compos/NAME`: fast-code's `learned.scm` in `~/.compos/fast-code`, learned web parsers in `~/.compos/web/parsers`, trips in `~/.compos/travel`. The home migration `personal-data-out-of-packages` moved them there on 2026-11-15.

## Install and update (straight-like)

- Each repo is a full git clone in `~/.compos/repos/NAME`. The manager needs only git. jj is not part of the package design. The package directory goes on `load-path`. No build step.
- `init.scm` declares packages: `(use-package 'spotify)`. The manager finds the recipe, clones if necessary, loads, and harvests the autoload cookies.
- `~/.compos/packages.lock` pins each repo to a commit. `package-freeze` writes it. `package-thaw` checks out the pinned commits.
- `package-develop` points a package at a local checkout. Edits there take effect on save, as they do in core today.

## PRs while working

A package directory is a real clone. Edits to a package are edits to its clone. `package-pr` commits the changed hunks to a branch, pushes to the user's fork with `gh`, and opens the PR. The package follows that branch until the PR merges. The next update moves it back to upstream.

The never-branch rule applies to the core repo only. Package PRs use branches because upstream PRs need them.

## Updates: the packages app

`M-x packages` opens an app with one row for each package. Columns: tier, source, pinned commit, local changes, ahead/behind upstream, open PR and its CI, API compatible. Actions on a row and on its detail page: update, diff, PR, pin, develop, remove. A background `git fetch` publishes an event when it completes. The app updates on that event and does not poll.

## Updates follow the release, and fail forward

Packages have no versions of their own. A compos release is the heartbeat:

- **Release lock.** At each tag CI runs the tests of every compos-dev package with that compos and writes the commit of each package that passed into `priv/standard.lock` (`package-core-pins`). The first boot of a new release runs `package-follow-release!` (package `package-update`), which moves every pin of `packages.lock` to those commits. A package from the user's own source follows its newest commit (`package-update-target`). In `M-x packages`, `u` updates the package at point (`package-update!`) and `U` updates every package (`package-update-all!`). The updates column says held, release pin, N behind or up to date.
- **Breaking changes.** A recipe's `:major N` goes up only when a package breaks its own API: a renamed or removed public function, command, setting or data. A dependent says `(:requires ((linear 2)))`. compos's own API stays the recipe's `:api` (`compos-api-version`). A package that needs a newer `:api` does not load, and the message says why.
- **Fail forward.** An update never stops at a break. `package-update!` compares the public names of the package before and after the update (`package-api`). When names are gone or `:major` went up, `package-fail-forward!` finds each use in the user's own code (`package-user-code-files`: init.scm, custom.scm, personal packages, develop checkouts, clones of the user's own sources). It takes the replacement for each name from the package's CHANGES file or commit messages (`package-update-replacement`), files a todo with the plan (`package-fix-plan`), and starts a chat on it. The chat ends at `todo-review`, so nothing is pushed until the user reviews it. `package-fix-group`, `package-fix-project` and `package-fix-start-chat` choose where the todo goes and whether a chat starts.
- **Escape hatch.** `h` holds a package at its commit (`package-hold!`); `packages.lock` marks it `held #t`, and updates skip it. Each update keeps the commit it left as `previous`. `r` (`package-rollback!`) puts that commit back and holds the package there.
- **Ship just Scheme.** `M-x release-hot-patch` (package `release`) loads the .scm files changed since the stable compos's commit into the stable compos over `release-stable-socket`. It copies them into the overlay folder in the stable state directory (`release-overlay-dir`). At boot, `release-overlay-boot!` puts that folder first on load-path and loads its files over priv's. The overlay names the commit it patches, so a full install clears it. When only Scheme changed since the last tag, CI attaches `compos-VERSION-scheme-BASE.tar.gz` with that release's standard.lock. compos-update takes this bundle when the stable compos runs BASE (`release-update-scheme!`), and no restart is needed.
## Assignment - first cut

### 1. Core (compulsory) - only what boot needs

Boot means: the daemon starts, the browser draws a frame, the user opens, edits and saves a file, runs M-x, sets a variable, and installs packages.

- Kernel and buffers: advice, build-identity, custom, db, dismiss, emacs-names, events, format, holds, messages, migrations, scratch, title, watchers, cron, daemons, minibuffer, tree, buffer-relations, tramp (the file primitives that dired and the editor call)
- Windows and panes: panes, panes-mode, panes-history, popper, window, window-log, window-names, window-settings, groups, group-config, tab-bars
- Input and UI: appearance, capf, completion, keymaps, keys, modeline, palette, prompts, switch, tabulated-list, transient, detail, components, apps
- Packages: package (the manager), package-manager (install and uninstall), package-update (updates follow the release and fail forward), packages (the app), http (the manager fetches recipes)

### 2. Standard (`scheme/stdlib`) - quality of life

The everyday set that most users want. On by default. Each one can be turned off.

- Agents and chat: agent, agent-connectors, agent-listen, agent-machine, agent-permissions, agent-sandbox, agent-session, agent-transcript, agent-verbs, ai, chat, chat-mode, llm-config, llm-connectors, llm-gate, llm-presets, models, model-rules, mcp, mcp-hub, skills, subagents, agent-fleet, tools, tool-results, help-chat, decide (the agents' shell gate asks it), jev
- Tasks: todo, workflows, self-healing
- Code: code, chrome, diff-mode, git, jj, provenance, project, worktrees, treesit, lsp, comint, compile, repl, test, paredit, scheme-ide
- Text: morg (with morg/*: blocks, chat, preview and the tutorial read it), pdf, markdown-mode, mermaid, isearch, occur, register, bookmark, visual-line, preview, file-view
- Navigation: ibuffer, mode-list, help, peek, pane-menu, pane-overview, panes-board, window-flash, workspace-mode, events-list, collect, index, content-cache, content-scale, housekeeping, app-watch
- Apps: anchor (the page anchors every app reads by), app-registry, site-app (a website as a list-and-page app)
- Files: autorevert
- Editing styles: evil, cua, vscode
- Setup: setup, setup-wizard, tutorial, howto, show-keys
- Ops: release, telemetry

### 3. Community (one repo each)

- Mail and calendar: notmuch, google, calendar, agenda
- Services: linear, sentry, doppler, irc, whatsapp, imessage, feeds, graphql
- Web: web, xslt, web-server, webhooks, endpoint, sockets
- Writing: org, writing, ghost-rewrite, annotate, html-edit
- Diagrams and media: chart, draw, image-gen, screenshot, recording
- Agent extras: orchestrate, peers, predict, recall, needle, laya, fast-code, herdr, herdr-agent, herdr-claude, connectors/gemini, connectors/kimi, training
- Apps: amazon, recruiting, doom, doom-lite, insta, linkedin, movie, px0, spotify (with visualisers), substack, spreadsheet, slides, onboarding
- Other: anon, handheld, racket

Some of these can share a repo when they always go together, for example notmuch with google, calendar and agenda.

### Dev-only (stays in core under `scheme/dev/`)

drive-eval, fast-code-eval, decide-eval, palette-eval, events-demo, test-browser, perf, agent-perf, profile.

## Steps

1. Run a dependency check on the table. Every `require` from a core file to a non-core file is a break. Fix each one: move the file into core, or invert the dependency with a hook.
2. Build recipes, `use-package`, the lockfile and `package-develop`. Replace `package-install!`.
3. Make `compos-packages` and the first community repos with `git filter-repo`. History moves with the files.
4. Build the packages app and `package-pr`.
5. Make the release bundle the pinned standard packages.

## Open points

- The GitHub org is `compos-dev` (chosen 2026-11-15): `compos-dev/compos-packages` and the community repos live there. In a recipe, `:repo NAME` without a user means `compos-dev/NAME` (`package-default-org`). The core stays at `svs/compos` for now.
