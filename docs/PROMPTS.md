# Prompt composition

Prompt composition is a public architectural contract. A prompt is an ordered
set of named fragments with an explicit lifecycle, not an incidental string
assembled near an HTTP call.

## Sources and boot order

`priv/editor.scm` defines `chat-preamble`, the stable conversation and buffer
role. Checked-in standing guidance lives as plain text in `priv/prompts/`.
`priv/packages/prompts.scm` names and orders those files, adds generated catalog
and recipe fragments, and owns the canonical join and prompt inspection.
Feature packages own the facts for their mode-specific fragments. The package
loads after `skills.scm`, when all bundled providers are ready. `init.scm` is
the authoritative answer to when a prompt source becomes available.

The code-agent fragment itself is `code-agent-system-note` in
`priv/packages/code.scm`. It is loaded because `priv/init.scm` explicitly loads
that package. Enabling `code-agent-mode` makes the fragment eligible. The first
send copies the composed fragment into the conversation snapshot.

## Direct API turns

At the start of every direct API turn, `Agent.send_prompt` asks
`Compos.Core.Agent.Backend.context/2` for context. The registered Scheme closure
is `chat-thread-context` in `priv/packages/chat.scm`.

The first turn stores `chat-prompt-snapshot` with the conversation.
`chat-system-prompt-parts` returns this frozen set on every later turn.
`chat-live-system-prompt-parts` computes current sources without changing the
snapshot. With tools enabled the fragments are:

1. Shared text-file fragments from `priv/prompts/`, in their declared order.
2. `catalog` and `recipes` — generated shared guidance.
3. `mcp` — notes for the remote servers this chat actually holds.
4. `skills` — the currently available skill index.
5. Buffer-local mode fragments, in their injection order.
6. `chat-preamble` — the chat or companion role.

Empty fragments are omitted. `prompt-parts-text` performs the sole canonical
join using two newlines. This data form lets tests and diagnostics verify order,
presence and duplication without parsing prose.

## ACP sessions

ACP tools and prompts are fixed when a session starts.
`agent-system-prompt-parts` uses the same conversation snapshot as the direct
lane. It contains the same shared text-file, `catalog`, and `recipes` fragments,
then `mcp` and the buffer-local mode fragments. `hello` is a compatibility and
RPC view that joins those same ACP fragments; it is not separate guidance.
`agent-live-system-prompt-parts` computes current sources for inspection.
`agent-config-with-system-parts` appends them through
`_meta.systemPrompt.append`. A connector or preset change restarts or
reattaches the session. A direct API turn can rebuild its context without this.

The two lanes must express the same capabilities even though their protocols
have different lifecycles. A prompt change is incomplete until both lanes are
considered and their focused tests pass.

## Mode fragments

Modes inject named fragments with `prompt-part-set!` and remove them with
`prompt-part-remove!`. The ordered `prompt-parts` buffer-local holds this
derived state. Mode setup must rebuild it after restore or reload.

`chat-mode` enables `code-agent-mode` during setup because every chat is an
agent surface. `code-agent-mode` owns the `code-agent` fragment. A mode change
updates the live fragment source. It does not change a frozen conversation.

Run `M-x chat-refresh-prompt` to replace the snapshot from current sources.
This command intentionally breaks the direct prompt cache. It reconnects an
idle ACP session immediately. It defers a busy ACP reconnect until the next
turn.

## Quiet editor policy

`priv/prompts/quiet-editor.txt` owns the default visible-state policy. Both
connector lanes receive it as the named `quiet-editor` fragment.

Agents work on named buffers without displaying or selecting them. Display is
only for an explicit presentation request. The catalog marks visible-state
operations with the `display` effect. The agent-facing `apropos` tool excludes
that effect by default and accepts `include-display` for presentation work.
Public Scheme `apropos` remains complete. Tool enforcement can use the same
checked-in effect later without changing this prompt contract.

## Conversation context

`priv/prompts/chat-context.txt` tells every agent to call `(chat-context)` once
at the start of a task. The structured result identifies the chat buffer,
agent, connector, model, group and members, companion buffers and roles,
workspace directory, visible editor context, and whether the prompt is still
prospective or frozen. Agents call it again when group membership, companions,
or visible work changes. This keeps identity and buffer guidance uniform across
direct and ACP agents without baking volatile state into the cached prompt.

## Inspection

`M-x chat-show-prompt` opens a read-only help page for the selected chat. The
page shows the connector lane, lifecycle, ordered fragment names, byte counts,
each fragment, and the final canonical join.

The page shows the frozen conversation prompt when one exists. Before the
first send, it shows the prospective prompt from current sources. The ACP
connector can also supply a system prompt that compos does not own.

## Stability and volatile context

System text and tool definitions form the reusable prompt-cache prefix. A chat
freezes both at the conversation start. Source edits and mode changes cannot
rewrite the system prefix midway. Buffer contents, the newest user request,
tool results and other changing material belong in messages or context blocks.

## Change checklist

When changing prompt behavior:

1. Name the fragment and its owner.
2. State whether it is evaluated per turn or per session.
3. Preserve the named-fragment order unless the change intentionally breaks
   the cache prefix.
4. Check both direct API and ACP composition paths.
5. Test fragment presence, absence, order, idempotence and final wire text.
6. Keep secrets and large live document bodies out of standing fragments.
