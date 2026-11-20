# chat-mode

`chat-mode` runs a conversation with an AI agent inside an ordinary buffer. Every group owns a companion chat, and the agent sees your visible buffers, group companions, and working directory automatically.

## Open

- `C-c c` or `C-c w` (`chat-companion`): open or toggle the current group's chat.
- `C-c n` (`chat-new`): start a new chat in the current group.
- `C-c RET` (`chat-companion-ask`): ask the group chat a question without leaving your current buffer.
- `C-c r` (`chat-send-region`): insert the selected region into the group chat's input box.
- `M-o` (`llm-companion-open`): open a context-aware chat tailored to the current buffer or page.
- `C-c a n` (`agent-open`): spawn a separate agent thread for an independent task.

## Keys

| Key | What it does |
| --- | --- |
| `RET` | Send the input |
| `S-RET` | Insert a newline without sending |
| `C-RET` | Send ahead of queued messages (steer the active turn) |
| `C-g` | Stop the reply that is running now |
| `C-c C-k` | Reset the chat: clear the transcript and keep the model |
| `C-c b` | Open `llm-configure` for connector, model, effort, tools, and prompt sections |
| `C-c m` | Switch the model for this chat |
| `C-c p` | Cycle permission stance (`approve`, `auto`, `ask`) |
| `C-c C-y` / `C-c C-a` / `C-c C-n` | Allow once, allow always in this chat, or deny a pending tool call |
| `C-c $` | Show token usage and cost for this chat |
| `C-c t` | File this chat as a shared todo |
| `Tab` | Fold or expand the tool output block at point |
| `C-c C-v` | Toggle between rich and plain transcript view |
| `M-<up>`, `M-<down>` | Step between messages or blocks in the transcript |
| `M-<`, `M->` | Jump to the first or newest message |

## Shared chat surface (`chat-surface-mode`)

`chat-mode`, Telegram, WhatsApp, and other messaging views share `chat-surface-mode`. Scrolling up keeps the transcript where you read; typing in the input returns to the newest message. `<up>` and `<down>` walk your previous inputs.

## Skills and recovery

- Type `/NAME` at the start of a message to load a skill (browse skills with `M-x chat-show-skills`).
- `M-x chat-unstick`: clear a stale in-flight indicator when no runtime is active.
- `M-x chat-heal`: repair orphaned tool calls or tool results after a crash.
- `M-x chat-refresh-prompt`: rebuild the frozen system prompt from current sources.
- `M-x chat-tool-surface`: inspect the exact MCP servers attached to this chat.

See also: [chat-list-mode](chat-list-mode.md), [ai-mode](ai-mode.md), [mcp-hub-mode](mcp-hub-mode.md), [07. AGENTS](../07.%20AGENTS.md).
