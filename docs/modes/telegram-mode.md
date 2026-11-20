# telegram-mode, telegram-detail-mode, and Telegram bot

compos supports two distinct Telegram workflows:

1. **Personal Telegram client (`M-x telegram`, `telegram-app`):** read and reply to all of your own Telegram chats as yourself inside compos.
2. **Official Telegram bot (`telegram` package):** message your compos agents from your phone via a `@BotFather` bot, with zero ToS risk.

## 1. Personal Telegram app (`M-x telegram`)

`telegram-mode` lists your chats newest first with unread counts, and `telegram-detail-mode` opens each conversation beside it using the shared `chat-surface-mode` input bar.

| Mode | Key | What it does |
| --- | --- | --- |
| `telegram-mode` | `RET` | Show conversation beside the list |
| `telegram-mode` | `r` / `R` | Reply as yourself / mark chat read |
| `telegram-mode` | `s` | Search across all Telegram chats |
| `telegram-mode` | `/` / `g` / `q` | Narrow, refresh, or quit |
| `telegram-detail-mode` | `RET` / `S-RET` / `ESC` | Send as yourself / newline / clear input |
| `telegram-detail-mode` | `<up>` / `<down>` | Walk previously sent inputs |
| `telegram-detail-mode` | `M-<up>` / `M-<down>`, `M-<` / `M->` | Step messages / jump to first or newest |
| `telegram-detail-mode` | `C-c r` / `C-c s` / `C-c g` | Mark read / search all chats / refresh |

Setup: run the package's MTProto bridge (`bridge/bridge.py`, using official Telegram `api_id` and `api_hash` from `my.telegram.org`), then set `telegram-bridge-url` (for example `http://HOST:8792`) and `telegram-bridge-token` (`TELEGRAM_BRIDGE_TOKEN`). Telegram officially allows third-party MTProto clients, though excessive automated messaging still triggers flood limits.

## 2. Official Bot API (`telegram` package)

Best for controlling compos agents remotely from your phone without exposing your personal Telegram chats:

- Create a bot via `@BotFather` and store the token in `TELEGRAM_BOT_TOKEN` (`telegram-bot-token`).
- Allowlist your Telegram user ID in `telegram-allowed-users`, for example `'((123456789 "You" owner))`.
- Optionally route people or group chats to specific compos groups with `telegram-chat-routes` (unrouted chats get their own `Telegram: NAME` group).
- Set `telegram-enabled` to `#t` so the bot starts at boot. Photos, files, and voice notes save into `telegram-files-directory`, and `telegram-progress` streams tool progress back to Telegram.

See also: [whatsapp-mode](whatsapp-mode.md), [notmuch-mode](notmuch-mode.md), [chat-mode](chat-mode.md).
