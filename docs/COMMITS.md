# Commit messages

The commit history is the changelog. Users and their agents read it to learn what changed in the editor. Write each message for them, not for the person who wrote the code.

## Two levels

- A jj change holds one change. Its description follows the format below. An agent writes it with `(jj-describe! TEXT)` after it saves the completed change.
- A git commit collects the jj changes since the last commit. The git committer writes its message from all of those jj descriptions.
- The git commit message must be complete on its own. When a jj description is empty, or names only internals, the committer reads that change's diff and writes the missing part.
- Never make a git commit with an empty message, or with a message that covers only some of its changes.

## Format

```
area: what changed, in the user's words

What the user sees now, and why it changed. One to three short
paragraphs or bullets.

Breaking: what a user or a config must change.

For agents:
- new, changed or removed functions, commands, settings and keys

Agent: chat-...
```

- **Subject:** `area: summary`, at most 72 characters. The area is the package or surface the user knows: `panes`, `chat`, `chat list`, `mail`, `morg`, `client`, `imenu`. The summary says what the user gets. Write `panes: a floating preview no longer changes the layout`, not `float-show! uses builtin-split-window!`.
- **Body:** a blank line after the subject. Describe the behaviour before and after, and the reason. Use no internal names in the body.
- **Breaking:** include this line when a command, setting or key is removed or renamed, or when a default changes. Omit it when nothing breaks.
- **For agents:** list the public API that changed: functions, commands, `defcustom` settings, modes and keys, with their new defaults. Omit internal helpers. Omit the section when no public API changed.
- **Agent:** `jj-describe!` adds this line. Do not remove it.

## Rules

- One change per jj change. When the subject needs a semicolon or an "and" between two unrelated things, split the change.
- A git commit that holds several changes has a subject that sums them up. Its body has one short section per change, each with its own `area:` line.
- Write to ASD-STE100 and in plain ASCII, as AGENTS.md says for all prose.
- Tests, refactors and comments without a change in behaviour go in a line of their own: `panes: internal: header comments for the model`.

## Example

```
panes: a floating preview no longer changes the layout

The preview card floats over the panes as its own window. Opening,
closing or redrawing it adds no pane and moves no window. C-x w
lists it as its own "floating" row: RET goes to it, k closes it.
```

```
chat list: no preview card by default

Moving through C-x C-c no longer opens a preview of each chat.

For agents:
- new setting chat-list-preview, default #f
```
