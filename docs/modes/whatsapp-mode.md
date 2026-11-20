# whatsapp-mode and whatsapp-chat-mode

`whatsapp-mode` lists recent WhatsApp chats inside compos, and `whatsapp-chat-mode` renders each conversation message by message so you and your agents can read threads, search history, and draft replies in context.

## Open

- `M-x whatsapp`: open the WhatsApp workspace in the `*WhatsApp*` group (`whatsapp-group`).
- `M-x whatsapp-list`: open the recent chat list.
- `M-x whatsapp-feed-start`: turn incoming messages into `whatsapp:PHONE` events on the event bus (`whatsapp-feed-enabled`, `whatsapp-notify`).

## Keys

| Mode | Key | What it does |
| --- | --- | --- |
| `whatsapp-mode` | `RET` | Open conversation in `whatsapp-chat-mode` |
| `whatsapp-mode` | `r` | Reply to the selected chat |
| `whatsapp-mode` | `/` / `g` / `q` | Narrow, refresh, or quit |
| `whatsapp-chat-mode` | `<up>` / `<down>` (`n`/`p`, `j`/`k`) | Move message by message and mark the current message |
| `whatsapp-chat-mode` | `r` | Reply quoting the marked message |
| `whatsapp-chat-mode` | `g` / `q` | Refresh or quit |

## How compos connects

compos talks to WhatsApp through an MCP server named `whatsapp` (plus an optional REST feed URL in `whatsapp-feed-bridge`) registered in `~/.compos/ai-config.scm`:

```scheme
(mcp-register! 'whatsapp (list 'type "http" 'url "https://HOST/mcp"))
(define-preset! 'whatsapp "Read and reply to WhatsApp" '(whatsapp))
```

The server provides tools such as `list_messages` and `send_message`.

## Choosing a WhatsApp CLI or bridge (ToS, bans, and legality)

WhatsApp has no official personal-account API or CLI. Before connecting WhatsApp, understand the trade-offs and pick an approach deliberately:

- **Unofficial Linked Devices bridges (`whatsmeow` Go bridges such as `whatsapp-mcp` / `wacli`, Baileys Node bridges, or `mautrix-whatsapp`):** link via QR code like WhatsApp Web and give full access to personal chats. **Risk:** automated access violates WhatsApp's Terms of Service. Meta can disconnect the linked device, rate-limit, or ban the phone number -- especially for bulk sends, rapid automated replies, or fresh cloud IPs.
- **Official WhatsApp Business Cloud API:** Meta-sanctioned and compliant for business automation, but requires a registered Business phone number and does not access an existing personal WhatsApp history.
- **Read-only via Chrome extension:** keeping WhatsApp Web open in your own Chrome profile avoids running an unofficial protocol client, though it is slower and less structured than an MCP bridge.
- **Privacy and compliance:** syncing third-party chats locally or sending message transcripts to external LLM providers may conflict with workplace policies, NDAs, or local data-protection laws. Check before connecting a work number.

## Safe agent rules

- Incoming WhatsApp events wake chats with `untrusted?` set to `#t`, so compos stops and asks before an agent sends, spends, or destroys.
- Keep outbound WhatsApp sends behind explicit human approval (or `todo-review` for agent-drafted replies). Never auto-reply to unknown senders or groups.

See also: [telegram-mode](telegram-mode.md), [notmuch-mode](notmuch-mode.md), [11. CONNECTED APPS](../11.%20CONNECTED%20APPS.md).
