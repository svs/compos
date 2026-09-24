# Prompt composition

Prompt composition is a public architectural contract. Every fragment is one
section: each Markdown prompt file, each generated part (`catalog`, `recipes`,
`mcp`), and each part a mode adds (`chat-preamble`, `code`, `code-agent`).

`C-c b` (`llm-configure`), then `+` (more fields), then `i` opens the
sections as switches, in prompt order. The default files are
`identity`, `quiet-editor`, `scope`, `chat-context`, `scheme`, `discovery`,
`reading`, `repository` and `browser`.

Toggle any number, then press `x` once to apply them. `a` selects all, `n`
selects none, and `C-g` discards the draft. `chat-show-prompt` marks the live
composition with `●` and `○`. Saved LLM bundles record disabled section names.
A name that no section has any more switches nothing off.
Each bundle keeps the shortcut key assigned on its first save. Updates,
reordering, and restarts do not change it. New sections default on.

## Sources and grouping

Standing guidance lives as Markdown files. `prompts-directories` lists the
directories; the default is `priv/prompts/`. Each `FILE.md` is one section named
`FILE`. An earlier directory wins a name, so a user adds a directory with

```scheme
(add-to-list! 'prompts-directories "~/my-prompts")
```

and its files override the default files of the same name. New names are new
sections. `(prompt-files)` answers every file as `(NAME PATH)`. The default
files keep a fixed order (`*prompt-file-order*`), so the prompt bytes stay
stable; other files follow by name.

`scheme/packages/chat-mode.scm` defines the stable chat preamble and code-edit protocol.
Feature packages can add focused, named fragments with `prompt-part-set!`.
`scheme/packages/prompts.scm` owns the files, the canonical join, selection,
snapshots, and inspection.

## Direct API turns

At the start of every direct API turn, `Agent.send_prompt` asks
`Compos.Core.Agent.Backend.context/2` for context. The registered Scheme closure
is `chat-thread-context` in `scheme/packages/chat.scm`.

`chat-system-prompt-parts` returns the selected sections.
`chat-thread-context` joins them with `prompt-parts-text` and places the result in
the request's `system` field. The first send freezes the section bodies and
selection in `chat-prompt-snapshot`; later direct turns reuse that snapshot.
Snapshot writes hold an immutable buffer reference before composing sections.
A rename during composition therefore keeps the snapshot on the same chat.
Direct turns, ACP setup, and explicit prompt freezing use this rule.

## ACP sessions

`agent-system-prompt-parts` returns the same selected sections for ACP.
`agent-config-with-system-parts` appends each section through
`_meta.systemPrompt.append` when the session starts. ACP tools and prompts are
fixed for that session. A connector or preset change restarts or reattaches it.

The direct and ACP lanes must express the same capabilities even though their
protocols have different lifecycles. A prompt change is incomplete until both
lanes and the inline `M-o` session path are checked.

## Context and cache stability

The system prompt contains no generated workspace or group-member list.
`priv/prompts/chat-context.md` is static. It tells the agent to call
`(chat-context)` at the start of a task and again when the user's working context
changes. That result supplies the current chat, group members, companions,
roles, workspace directory, visible editor context, and prompt state.

Changing a group's members therefore does not change the system-prompt bytes or
invalidate the cache. Buffer contents, names, the newest user request, tool
results, and other changing material belong in messages or tool results.

## Mode fragments

Modes inject named raw fragments with `prompt-part-set!` and remove them with
`prompt-part-remove!`. The ordered `prompt-parts` buffer-local holds this derived
state. Mode setup must rebuild it after restore or reload.

`chat-mode` enables `code-agent-mode` during setup because every chat is an
agent surface. `code-agent-mode` owns the `code-agent` raw fragment. Mode changes
update the prospective source, not a frozen conversation.

A package adds its section to every chat the same way, from `chat-mode-hook`.
A chat restored or opened before the package loaded missed that hook, so the
package also sets the part on every chat that exists when it loads:

```scheme
(define (todo--chat-mode-hook!)
  (prompt-part-set! (current-buffer) "todo" todo-prompt))

(add-hook! 'chat-mode-hook 'todo--chat-mode-hook!)

(for-each (lambda (b)
            (when (chat-buffer? b)
              (prompt-part-set! b "todo" todo-prompt)))
          (buffer-list))
```

The todo package adds `todo`. Section names are unique: the last fragment of a
name wins, in the place the name first took, so a buffer part replaces a prompt
file of that name.

A project's `compos.scm` or a group's `ai-config.scm` runs with the chat
current, and turns one section off or on:

```scheme
(prompt-section-off! (current-buffer) "todo")
(prompt-section-on! (current-buffer) "todo")
```

The switch is the chat's `prompt-disabled-parts`, the same one `C-c b` sets. It
persists with the chat and applies when the prompt is composed, so it does not
matter which runs first: the config or the part it names.

Run `M-x chat-refresh-prompt` to replace the snapshot from current sources. This
command intentionally breaks the direct prompt cache. It reconnects an idle ACP
session immediately and defers a busy ACP reconnect until the next turn.

## Quiet editor policy

`priv/prompts/quiet-editor.md` owns the default visible-state policy and appears
as its own section. Agents work on named buffers without displaying or selecting
them. Display is only for an explicit presentation request.

## Inspection

`M-x chat-show-prompt` opens a read-only help page for the selected chat. It
shows the connector lane, lifecycle, the ordered section names, byte counts,
each selected section, and the final canonical system text.

The page shows the frozen conversation prompt when one exists. Before the first
send, it shows the prospective prompt from current sources. An ACP connector can
also supply a system prompt that compos does not own.

## Change checklist

When changing prompt behavior:

1. Name the fragment (its section) and its owner.
2. Keep dynamic workspace state out of the system prompt.
3. Preserve section order unless the change intentionally breaks the cache.
4. Check direct API, ACP, and inline composition paths.
5. Test presence, absence, order, idempotence, and final system text.
6. Keep secrets and large live document bodies out of standing guidance.
