# mcp-hub-mode

`mcp-hub-mode` displays every MCP server registered in compos with its live connection state, tool count, and transport (`stdio` or `http`).

## Open

- `C-c a m` or `M-x mcp-hub`.
- `M-x mcp-status` shows a quick summary of the servers attached to the current chat.

## Keys

| Key | What it does |
| --- | --- |
| `RET` | Show full details and tool list for the server at point (`mcp-detail-mode`) |
| `s` / `S` | Start the server at point / start all servers |
| `k` / `K` | Stop the server at point / stop all servers |
| `r` / `R` | Restart the server at point / restart all servers |
| `/` | Narrow the list |
| `g` / `q` | Refresh or quit |

## Notes

- MCP server declarations and tool presets live in `~/.compos/ai-config.scm` (`mcp-register!` and `define-preset!`). For security, compos refuses those registration calls from inside an agent chat.
- An ACP agent fixes its `mcpServers` list at session start; after enabling a new preset in `C-c b`, reconnect or start a fresh turn if prompted.

See also: [ai-mode](ai-mode.md), [chat-mode](chat-mode.md).
