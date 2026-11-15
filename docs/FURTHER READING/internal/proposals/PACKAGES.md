# Packages - three tiers of repos

Status: proposal, 2026-11-15. The assignment table is a first cut. A dependency check must confirm it before any file moves.

## The three tiers

| Tier | Repo | Count | Installed | Who owns it |
|---|---|---|---|---|
| 1. Core | `compos` (this repo) | one | always, cannot be removed. Only what boot needs | the compos team |
| 2. Standard | `compos-packages` | one repo, many packages | on by default, the user can turn each one off. Quality of life: chat, todo, git, code | the compos team, PRs welcome |
| 3. Community | one repo per package, anywhere on GitHub | unlimited | only when the user asks. Mail, linear, apps, services | the package author |

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

### 2. Standard: `compos-packages`

```
compos-packages/
  recipes.scm            ; one recipe for every standard package
  index.scm              ; recipes of known community packages (the MELPA role)
  mail/notmuch.scm
  mail/notmuch-test.scm
  linear/linear.scm
  ...
```

One directory for each package. One clone gives all of them. One CI runs all of their tests against core main.

### 3. Community: one repo each

```
compos-spotify/
  recipe.scm             ; (spotify :requires (http components) :api 3)
  spotify.scm
  spotify-test.scm
```

A community package gets into the `M-x packages` list when its recipe is in `compos-packages/index.scm`. A PR to that file adds it. A user can also install by URL without the index.

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

## Assignment - first cut

### 1. Core (compulsory) - only what boot needs

Boot means: the daemon starts, the browser draws a frame, the user opens, edits and saves a file, runs M-x, sets a variable, and installs packages.

- Kernel and buffers: advice, anchor, autorevert, build-identity, custom, db, dismiss, emacs-names, events, format, holds, messages, migrations, scratch, title, watchers, cron, daemons, minibuffer, tree, buffer-relations
- Windows and panes: panes, panes-mode, panes-history, popper, window, window-log, window-names, window-settings, groups, group-config, tab-bars
- Input and UI: appearance, capf, completion, keymaps, keys, modeline, palette, prompts, switch, tabulated-list, transient, detail, components, app-registry, apps
- Packages: package (the manager), packages (the app), http (the manager fetches recipes)

### 2. Standard (`compos-packages`) - quality of life

The everyday set that most users want. On by default. Each one can be turned off.

- Agents and chat: agent, agent-connectors, agent-listen, agent-machine, agent-permissions, agent-sandbox, agent-session, agent-transcript, agent-verbs, ai, chat, chat-mode, llm-config, llm-connectors, llm-gate, llm-presets, models, model-rules, mcp, mcp-hub, skills, subagents, agent-fleet, tools, tool-results, help-chat
- Tasks: todo, workflows, self-healing
- Code: code, chrome, diff-mode, git, jj, provenance, project, worktrees, treesit, lsp, comint, compile, repl, test, paredit, scheme-ide
- Text: markdown-mode, mermaid, isearch, occur, register, bookmark, visual-line, preview, file-view
- Navigation: ibuffer, mode-list, help, peek, pane-menu, pane-overview, panes-board, window-flash, workspace-mode, events-list, collect, index, content-cache, content-scale, housekeeping, app-watch
- Editing styles: evil, cua, vscode
- Setup: setup, setup-wizard, tutorial, howto, show-keys
- Ops: release, telemetry

### 3. Community (one repo each)

- Mail and calendar: notmuch, google, calendar, agenda
- Services: linear, sentry, doppler, irc, whatsapp, imessage, feeds, graphql
- Web: web, xslt, web-server, webhooks, endpoint, sockets
- Writing: morg (with morg/*), org, writing, ghost-rewrite, annotate, pdf, html-edit
- Diagrams and media: chart, draw, image-gen, screenshot, recording
- Agent extras: orchestrate, peers, decide, predict, recall, needle, jev, laya, fast-code, herdr, herdr-agent, herdr-claude, connectors/gemini, connectors/kimi, training
- Apps: amazon, ats, recruiting, doom, doom-lite, insta, linkedin, movie, px0, spotify (with visualisers), substack, spreadsheet, slides, site-app, onboarding, travel
- Other: anon, tramp, handheld, racket

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
