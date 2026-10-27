# Code browser

The code browser is how a person reads a codebase an agent wrote. The
reader sees a summary at every level: the project, a directory, a file, a
definition, a change. Every summary stays true to the code, and every name
in a summary is one key from the code it names.

There is no new table. Dired is the table of a directory. `scope-mode` is a
minor mode that toggles onto a Dired buffer or a file buffer, the way
`diff-mode` toggles onto them. It adds one column to Dired, one side window
that shows the summary of what point is on, and definitions in the popup.

This document is the user experience. `docs/CODE-BROWSER-PLAN.md` is the
mechanism and the build order.

> **Status (2026-09-24):** this is a design. `scope-mode`, the `*scope*` side
> window, the summary store, and the `scope-*` commands and tools are not
> built. `diff-explain` exists on `?` in diff-mode, not `e`. It shows the
> explanation in another window and updates no summary. `definition-show`
> exists and shows the definition in the other window, not in a popup.

This document is in this order:

1. The model.
2. The user stories.
3. The screens.
4. The rules: the mode, the side window, the popup, summaries, freshness, changes, links, presets, agents, persistence.
5. The acceptance list.

## Model

### Objects

- A **project** is a git checkout.
- A **node** is one thing the reader can stand on: the project, a directory, a file, or a definition.
- A **summary** is one morg file about one node, in `<root>/.compos/scope/`. A file summary says what the file does, why it exists, who calls it, and what to watch. A directory summary says what lives here, one card per entry. The project summary says what the project is, what to know, and how to run it. `recent.md` says what changed lately.
- **scope-mode** is a minor mode. On a Dired buffer it adds the `summary` column and the side window. On a file buffer it adds the side window. It claims no motion key: Dired moves like Dired, a file moves like a file.
- The **side window** is the popup (docs/POPUPS.md) showing the summary of the node at point. It follows point.
- A **definition popup** is a definition shown in the same popup, over the summary. `q` brings the summary back.

### The three rules

1. Every node has a summary, or a badge that says it has none. The reader never meets an empty side window.
2. A summary is fresh or it says `stale`. The reader never reads a lie without a badge on it.
3. Every name in a summary reaches the code with `M-.`: a path, a module, a function, a Scheme name. A name that reaches nothing says so and opens nothing.

## User stories

Read each story as a path:

> As a reader -> in this situation -> I want this outcome -> the editor behaves this way -> I use this command.

Some outcomes are automatic. Then the solution is a rule, not a command.

### As a reader who comes back to a project

#### I want to know what the agent did while I was away

- `M-x scope` opens Dired at the project root with scope-mode on. The side window shows the project summary. Each row has its one-liner; the `vc` column says `modified` where the working tree changed, and `stale` in the summary column says where the summary is behind.
- `M-x scope-recent` puts `recent.md` in the side window: what the last commits did, what is in flight.
- **Commands:** `scope`, `scope-recent`.

#### I want to see the changes themselves, with the reasons

- `M-x diff-mode` in the listing opens the diff for that directory, as today: one card per file, hunks folded.
- `e` on a card explains it: intent, mechanism, risk. The same call brings the file's summary up to date.
- **Commands:** `diff-mode`, `diff-explain`.

#### I want to check that a change did what the explanation says

- In the explanation, `M-.` on a name shows the definition as it is now, in the popup over the explanation. `q` brings the explanation back. `M-.` again on the same name goes to the code.
- **Command:** `definition-show`.

#### I want to catch up on one directory, not the whole tree

- `RET` on the directory opens it here, as Dired does. The side window shows that directory's summary. Rows say `modified` and `stale` where the work happened.
- **Command:** `dired-visit`.

### As a reader new to a codebase

#### I want the shape of the project before any file

- `M-x scope`. The side window is the project in one page. The rows are the top-level entries, each with one line.
- `n` and `p` move the rows; the side window shows each entry's full summary as point moves. No file opens.
- **Commands:** `scope`, Dired motion.

#### I want to walk down to the code without losing my place

- `RET` on a directory opens it here. `RET` on a file opens it in the other window, as Dired does today (`M-RET` opens it there and goes). `^` goes up. Point returns to the row I came from.
- **Commands:** `dired-visit`, `dired-up`.

#### I want to read a file's summary before its code

- On the file's row, the side window shows the summary. `M-x scope-doc` selects the side window so I can scroll it, fold it, or edit it. `q` returns to the listing.
- **Command:** `scope-doc`.

#### I want to see a file's definitions with what each one does

- `RET` opens the file; `M-x imenu` lists its definitions with line, kind, name, and doc. `M-x code-browse` turns on structural keys in it: `j` and `k` walk the definitions, and the side window shows the file's summary with the paragraph about the definition at point on top.
- **Commands:** `imenu`, `code-browse`.

#### I want to find the code behind a name I just read

- In the side window, `M-.` on the name shows the definition in the popup over the summary. A path shows the file, `path:42` the line, `Mod.fun` the function. `M-.` again goes there; `q` brings the summary back.
- A name that reaches nothing says "No definition of NAME" and opens nothing.
- **Command:** `definition-show`.

#### I want to jump to any definition in the project by name

- `M-x scope-find` reads a name with completion over every definition in the project and visits it, with the side window on that file's summary.
- **Command:** `scope-find`.

#### I want to narrow a big directory to what I am looking for

- `/` narrows the rows on every keystroke. It matches the name and the one-liner too, so `/ watcher` finds the file whose summary says watcher. `\` widens.
- **Rule:** list narrowing, as in every table.

### As a reader who opens a file first

#### I want the summary of the file I am in

- `M-x scope-mode` in the file. The side window shows the file's summary. It stays while I read; `M-x scope-mode` again takes it away.
- **Command:** `scope-mode`.

#### I want the summary of the definition I am in

- With scope-mode on in a file, the side window puts the paragraph about the definition at point first, when the summary has one, and the outline row for it above the page.
- **Rule:** the side window.

#### I want the listing my file is in, with the summaries

- `M-x scope-here` opens Dired on the file's directory with scope-mode on, point on the file.
- **Command:** `scope-here`.

### As a reader whose summaries do not exist yet

#### I want summaries for a project that has none

- Every row shows `?` in the summary column. `M-x scope-bootstrap` at the root writes them: files first, then directories, then the project page. The rows fill in as they land. The budget bounds the run; the modeline says when it stops.
- **Command:** `scope-bootstrap`.

#### I want one summary now

- `M-x scope-refresh` on the row queues it. The row shows `~` while the job runs, then its one-liner.
- **Command:** `scope-refresh`.

#### I want the summaries without spending on a large tree

- `scope-auto-refresh` off keeps the queue quiet; badges still show. `scope-bootstrap` in a subdirectory writes only that subtree. The `summarize` preset's tier is `fast`; `.project.scm` can set a cheaper model.
- **Rules:** freshness, presets.

### As a reader who edits

#### I want to correct a summary

- `M-x scope-doc` selects the side window. I edit and save. The summary keeps its key, so it stays fresh until the code changes. The next refresh carries my text as the existing doc and asks the model to keep what still holds.
- **Command:** `scope-doc`.

#### I want the summary to follow my edit to the code

- Saving the file marks its row `stale`. With auto-refresh on and budget left, the queue refreshes it; the directory and the project follow after their children settle.
- **Rule:** freshness.

#### I want a summary kept as I wrote it

- `#+pin: yes` at the top of a summary keeps the queue off it. The row shows `pinned` instead of `stale` when the code moves.
- **Rule:** summaries.

### As a reader who watches an agent work

#### I want to see what the agent touches as it works

- The listing follows the filesystem, as Dired does. A file the agent saves shows `modified` and `stale` on the next draw. The diff, if open, grows a card.
- **Rule:** the watch.

#### I want the explanation of the agent's change before I read the diff

- `e` on the card. The explanation folds open under the card, above the hunks.
- **Command:** `diff-explain`.

#### I want a chat about this file with the summary in it

- In a chat, `@explain` with a question sends the turn with the explain preset's tools, so the model reads the summary through `scope-read` before it answers.
- **Rule:** presets.

### As an agent

#### I want to read the codebase by its summaries before I read its files

- `(scope-outline ROOT)` returns every node with its one-liner and its freshness. `(scope-read REL)` returns one summary. Both are tools in the `explain` and `coding` presets.
- **Tools:** `scope-outline`, `scope-read`.

#### I want my edits to leave the summaries true

- An agent's save makes the file stale like any writer. The queue refreshes it on the same rules. An agent that wants the summary now calls `(scope-refresh! REL)`.
- **Tool:** `scope-refresh!`.

## The screens

### Dired with scope-mode on

`M-x scope` opens Dired at the project root with scope-mode on. The listing is Dired's, with one more column. The popup on the right is the side window.

```
+-- /Users/svs/src/compos/scheme/packages ---------------------------+-- *scope* ---------------------------------------+
| packages  61 entries . 2 modified                                   | code.scm                                stale     |
|                                                                     |                                                  |
|   ..                                                                | code.scm reads a source file with structural     |
|   morg/          --  Aug 30  drwxr-xr-x           babel blocks      | keys. It is a minor mode: the buffer keeps its   |
|   agent.scm    41K  Aug 29  -rw-r--r--            the chat's turn   | major mode and its file. h and l walk the tree,  |
|   annotate.scm 18K  Aug 27  -rw-r--r--   stale    margin notes on   | j and k the siblings.                            |
|   chat.scm     33K  Aug 30  -rw-r--r--            the conversation  |                                                  |
| > code.scm     58K  Aug 30  -rw-r--r-- modified   read a source f   | It exists because an agent writes code faster    |
|   diff-mode.scm 40K Aug 30  -rw-r--r--            the git diff as   | than a person reads it. code-browse is the       |
|   lsp.scm      22K  Aug 20  -rw-r--r--            diagnostics, def  | reader's verb set; imenu reads its outline       |
|   scheme-ide.scm 9K Aug 30  -rw-r--r--            scheme ide, defi  | through imenu-rows, and an agent reads the same  |
|   scope.scm     3K  Aug 30  -rw-r--r-- untracked ?                  | outline through code-outline.                    |
|                                                                     |                                                  |
| RET open  m mark  d flag  x trash  s sort  / filter  ^ up  g revert | Watch: nested tree-sitter nodes can share one    |
+---------------------------------------------------------------------+ byte range, so a node is (kind start end).       |
                                                                      +--------------------------------------------------+
```

The `summary` column is the first sentence of the entry's summary, or a badge: `?` none, `stale` behind the code, `~` refreshing, `pinned` kept by hand. The side window shows the whole summary of the row at point and moves with `n` and `p`.

### A file with scope-mode on

`RET` on `code.scm` opens it beside the listing. scope-mode is on in it because the listing had it on. The side window shows the file's summary, with the paragraph about the definition at point first.

```
+-- code.scm --------------------------------------------+-- *scope* ---------------------------------------+
| (define (code--goto-definition)                         | code.scm . code--goto-definition   L423  define  |
|   (let ((sym (code--symbol-at)))                        |                                                  |
|     (cond                                               | The seam for LSP. With a server attached,        |
|       ((not sym) (message "No symbol at point"))        | lsp-definition answers. Without one, the same    |
|       ((and (boundp 'lsp-definition)                    | file answers: the first line that defines the    |
|             (buffer-local (current-buffer) 'lsp-server))| symbol under point.                              |
|        (lsp-definition sym))                            |                                                  |
|       (else ...                                         | code.scm reads a source file with structural     |
|                                                         | keys. It is a minor mode: ...                    |
+---------------------------------------------------------+--------------------------------------------------+
```

### A definition in the popup

`M-.` on `lsp-definition` in the side window shows the definition in the popup, over the summary. `q` brings the summary back. `M-.` again goes to the code and keeps the popup on the summary.

```
+-- code.scm ---------------------------------------------+-- lsp.scm  (popup, over *scope*) ---------------+
| ...                                                     | (define (lsp-definition sym)                     |
|                                                         |   (let ((buf (current-buffer)))                  |
|                                                         |     (let ((id (lsp--server-of buf)))             |
|                                                         |       (if (not id)                               |
|                                                         |           (message "No language server here")    |
|                                                         |           (lsp-buffer-request id                 |
|                                                         |             "textDocument/definition" buf (point)|
|                                                         | q back to the summary . M-. go there             |
+---------------------------------------------------------+--------------------------------------------------+
```

### Changes

`M-x diff-mode` in the listing opens the diff for the directory, as today. `e` on a card explains it:

```
+-- *git: compos/scheme/packages ------------------------------------------------+
| v code.scm                                                   +41 -6   explained |
|   v what changed                                                                |
|     Adds a code--doc-inside reader so the outline's DOC column takes the        |
|     docstring inside a definition when nothing sits above it. Risk: a Python    |
|     file with a bare string as its first statement reads as a docstring; that   |
|     matches Python's rule.                                                      |
|   > @@ -637,6 +637,24 @@                                                        |
|   > @@ -683,4 +701,9 @@                                                         |
| > ../tests/code-test.scm                                     +18 -0             |
+--------------------------------------------------------------------------------+
```

The same call rewrites the file's summary, so after `e` the file's row is fresh again.

## Rules

### The mode

1. `scope-mode` is a minor mode. `M-x scope-mode` toggles it on the current buffer. `M-x scope` opens Dired at the project root with it on. `M-x scope-here` opens Dired at the current file's directory with it on, point on the file.
2. On a Dired buffer, scope-mode adds the `summary` column and the side window. Dired's keys, marks, flags, sorting, and filters are unchanged. `/` also matches the one-liner.
3. On a file buffer, scope-mode adds the side window. The buffer's keys are unchanged. `code-browse` is a separate minor mode and combines with it.
4. A buffer opened from a listing that has scope-mode on has scope-mode on. `M-x scope-mode` in it turns it off for that buffer.
5. The `summary` column and the side window read the store once per draw. A listing of 400 rows costs one store read, not 400.

### The side window

1. The side window is the popup, on the right by default (docs/POPUPS.md). Its buffer is `*scope*`. It is a morg buffer in `scope-doc-mode`: rendered, foldable, editable, `M-.` on every name.
2. It follows point: the list `'preview` hook in Dired and the post-command hook in a file buffer, with the same debounce the switcher's preview uses. It does not follow point in any other window.
3. In a file, the page starts with the outline row of the definition at point (line, kind, name), then the summary's paragraph about that definition when the summary has one, then the summary.
4. `M-x scope-doc` selects the side window. `q` there returns to the buffer it follows. Saving it writes the summary file.
5. Closing the popup (`C-\``) does not turn scope-mode off; the next `n` or `p` opens it again. `M-x scope-mode` off closes it.
6. One side window per frame. Two listings with scope-mode on share it; it shows the one that has point.

### The popup

1. `M-.` in the side window, in a change explanation, and in any morg document is `definition-show`. It shows the definition in the popup, over the summary (popper's stack, POPUPS.md rule 4).
2. `q` in the definition popup brings the summary back. `M-.` again on the same name goes to the definition in a work window and leaves the popup on the summary. `M-,` returns.
3. `M-.` in a file buffer is unchanged: `code-goto-definition`, LSP when attached.

### Summaries

1. A summary is a morg file. Directives at the top say what it is about (`#+scope`, `#+path`), what it read (`#+source`, `#+inputs`), who wrote it (`#+model`, `#+written`). `morg-scan` reads them; nothing else parses them.
2. A file summary is two to four short paragraphs, no headings: what, why, who calls it, what to watch. Paths are inline as `path/to/file.ext`. Names are inline as `name`. A paragraph that is about one definition starts with that name, so the side window can put it first.
3. A directory summary is one paragraph and one card per entry; noise entries (`_build`, `deps`, `node_modules`) have no card.
4. The project summary is one paragraph, a "Worth knowing" list, and "Running".
5. `recent.md` is two paragraphs: what the last commits did, what is in flight.
6. A row's one-liner is the first sentence of its summary.
7. `#+pin: yes` keeps the queue off a summary. Its row shows `pinned` instead of `stale` when the code moves.

### Freshness

1. A summary's key is the git blob sha of its input. A directory's key is its children's summary shas and its entry list. The project's key is the root summary sha and `HEAD`. A change explanation's key is the sha of the file's diff text.
2. A summary is fresh when `#+source` equals the key. Else it is `stale`. No clock is read.
3. A stale summary still shows, with the badge. A missing summary shows `?`.
4. The queue holds one job in flight. A job that waited while its input changed again is dropped and re-queued with the newest key. Children settle before parents.
5. Auto-refresh has a budget of calls per hour per project (default 60). The modeline of a scope-mode buffer shows it. A queue that meets the budget stops and says so; `scope-refresh` still runs by hand.
6. A hand-edited summary keeps its key. The next refresh carries the edited text as the existing doc.

### Changes

1. `M-x diff-mode` in a listing or a file opens the diff for that directory or file, as today.
2. `e` on a file card runs one `explain` call with the diff, the file, and the existing summary. It gets two sections: what changed, shown under the card; the updated summary, written to the store and marked fresh.
3. `recent.md` refreshes when `HEAD` moves or the working diff changes.

### Links

1. `definition-show`'s providers, in order: a path (`code.scm`, `code.scm:423`, `lib/foo.ex#L42`), a Scheme name, an LSP `workspace/symbol` when a server is attached, the project outline index.
2. A path resolves against the document's directory and then the project root. It is a link only when the file exists.
3. A name with a module (`Compos.Core.Git.diff`, `Mod.fun/2`) resolves through the outline index and LSP. A bare name resolves in the same order and takes the first hit.
4. A name that resolves nowhere says "No definition of NAME" and opens nothing.
5. `M-x scope-find` completes over the outline index and visits the definition.

### Presets

1. A summary job names a preset, never a model: `summarize` for files and directories, `explain` for changes, `recent.md`, and the project page.
2. A project sets its own in `.project.scm`: `(project-preset! 'summarize 'model "gpt-5.4-mini")`, `(project-tier! 'strong "gpt-5.6-sol")`.
3. `@explain what does this hunk do` in a chat runs that turn with the `explain` preset's model, system, and tools.

### Agents

1. `scope-outline`, `scope-read`, and `scope-refresh!` are tools. A chat with the `coding` or `explain` preset holds them, so an agent reads the summaries before the files.
2. An agent that edits a file makes it stale like any other writer. Its summary refreshes on the same queue.

### Persistence

1. scope-mode is a minor mode local; it survives a restart, and the mode setup reopens the side window on the next motion.
2. The store is files. A restart loses nothing. The queue is not persisted; a stale summary is stale until viewed or changed again.

## Acceptance

1. `M-x scope` in a project opens Dired at the root with scope-mode on, the `summary` column filled, and `*scope*` in the popup showing `project.md`; a project without a store shows `?` in the column and an empty-state page.
2. `n` and `p` in the listing move the side window to the row's summary; `RET` on a directory keeps scope-mode on in it.
3. `RET` on a file opens it with scope-mode on; the side window shows the file's summary; moving point across definitions changes the outline row and the first paragraph.
4. `M-x scope-mode` in a plain file buffer opens the side window with its summary; again closes it.
5. `M-.` on a path in the side window shows the file in the popup; on `Compos.Core.Git.diff` shows git.ex; on a Scheme name shows its definition; `q` brings the summary back; `M-.` again goes to the code; `M-,` returns.
6. Saving a file marks its row `stale` on the next draw; with auto-refresh on and budget left, the row shows `~` and then a fresh one-liner; the directory's summary refreshes after.
7. `M-x scope-refresh` queues one row; `M-x scope-bootstrap` at the root fills the tree and the modeline counts.
8. A hand edit to `*scope*` saves to the store and survives the next refresh as the existing doc in the prompt.
9. `M-x diff-mode` in the listing opens its diff; `e` on a card shows the explanation and marks the file's summary fresh.
10. `M-x scope-recent` shows `recent.md`; it refreshes after a commit.
11. `/ watcher` in the listing narrows to the rows whose one-liner says watcher.
12. A `.project.scm` preset override changes the model the next job sends.
13. `scope-outline` and `scope-read` return the store to a chat that holds them.
14. scope-mode survives `M-x restart-daemon` on every buffer that had it.
15. Dired's own tests are unchanged; scope-mode's tests bind dummy `<f9>` keys to its commands and never name a production key.
