# Prompt composition

Prompt composition is a public architectural contract. A prompt is an ordered
set of named fragments with an explicit lifecycle, not an incidental string
assembled near an HTTP call.

## Sources and boot order

`priv/editor.scm` defines `chat-preamble`, the stable conversation and buffer
role. Bundled packages then load in the order written in `priv/init.scm`:
`agent.scm`, `chat.scm`, `code.scm`, later `mcp.scm`, and finally `skills.scm`.
Definitions that cross that order use `boundp`; `init.scm` is the authoritative
answer to when a prompt source becomes available.

The code-agent fragment itself is `code-agent-system-note` in
`priv/packages/code.scm`. It is loaded because `priv/init.scm` explicitly loads
that package. Enabling `code-agent-mode` makes the fragment eligible; it does
not permanently copy prose into a chat record.

## Direct API turns

At the start of every direct API turn, `Agent.send_prompt` asks
`Aimax.Core.Agent.Backend.context/2` for context. The registered Scheme closure
is `chat-thread-context` in `priv/packages/chat.scm`.

`chat-system-prompt-parts` returns the exact ordered fragments sent on the
wire. With tools enabled they are:

1. `aimax-tools` — the intrinsic editor tool primer.
2. `mcp` — notes for the remote servers this chat actually holds.
3. `skills` — the currently available skill index.
4. `code-agent` — code-agent-mode's standing instructions, when enabled.
5. `chat-preamble` — the chat or companion role.

Empty fragments are omitted. `prompt-parts-text` performs the sole canonical
join using two newlines. This data form lets tests and diagnostics verify order,
presence and duplication without parsing prose.

## ACP sessions

ACP tools are fixed when a session starts. `agent-system-prompt-parts` in
`priv/packages/agent-connectors.scm` returns the ordered `code-agent`, `mcp`,
and `aimax-primer` fragments.
`agent-config-with-system-parts` appends them through
`_meta.systemPrompt.append`. A connector or preset change restarts or
reattaches the session. A direct API turn can rebuild its context without this.

The two lanes must express the same capabilities even though their protocols
have different lifecycles. A prompt change is incomplete until both lanes are
considered and their focused tests pass.

## Quiet editor policy

`*agent-quiet-prompt*` in `priv/packages/tools.scm` owns the default visible-state
policy. The direct lane receives it through `aimax-tools`. ACP sessions receive
it through `hello` in the `aimax-primer` fragment.

Agents work on named buffers without displaying or selecting them. Display is
only for an explicit presentation request. The catalog marks visible-state
operations with the `display` effect. The agent-facing `apropos` tool excludes
that effect by default and accepts `include-display` for presentation work.
Public Scheme `apropos` remains complete. Tool enforcement can use the same
checked-in effect later without changing this prompt contract.

## Stability and volatile context

System text and tool definitions form the reusable prompt-cache prefix. Keep
fragment wording and ordering stable across turns. Buffer contents, the newest
user request, tool results and other changing material belong in messages or
context blocks, not in stable standing fragments. Sort collections whose
incidental order can change.

## Change checklist

When changing prompt behavior:

1. Name the fragment and its owner.
2. State whether it is evaluated per turn or per session.
3. Preserve the named-fragment order unless the change intentionally breaks
   the cache prefix.
4. Check both direct API and ACP composition paths.
5. Test fragment presence, absence, order, idempotence and final wire text.
6. Keep secrets and large live document bodies out of standing fragments.
