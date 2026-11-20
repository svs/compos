# Mode guides

Every buffer in compos wears one major mode and any number of minor modes. A mode decides what keys do, how the buffer renders, and which commands apply. Press `C-h m` (`describe-mode`) in any buffer to read its live docstring and bindings.

## AI and chats

| Mode | Open with | Covers |
| --- | --- | --- |
| [chat-mode](chat-mode.md) | `C-c c`, `C-c n` | Conversations with an AI agent, steering, permissions, skills, models, cost, and recovery |
| [chat-list-mode](chat-list-mode.md) | `C-x C-c`, `M-x chat-list` | Live and archived chats, filtering, watching busy chats, bulk steering, and permission replies |
| [ai-mode](ai-mode.md) | `M-x ai`, `M-x llm-connectors` | Chat, group, and global LLM config, presets, prompt sections, and connector testing |
| [mcp-hub-mode](mcp-hub-mode.md) | `C-c a m`, `M-x mcp-hub` | Inspecting, starting, stopping, and restarting MCP servers |

## Communications

| Mode | Open with | Covers |
| --- | --- | --- |
| [notmuch-mode](notmuch-mode.md) | `M-x mail`, `M-x notmuch` | Email via direct Gmail API, `notmuch` + `lieer`, or IMAP, plus tagging, replies, and agent handoff |
| [whatsapp-mode](whatsapp-mode.md) | `M-x whatsapp` | WhatsApp threads via MCP, message replies, event feeds, bridge choices, and ToS/privacy caveats |
| [telegram-mode](telegram-mode.md) | `M-x telegram` | Personal Telegram client (MTProto bridge) and official `@BotFather` agent bot |
| [imessage-mode](imessage-mode.md) | `M-x imessage`, `M-x otp` | macOS Messages and SMS reading, replies, and one-time code extraction |
| [irc-mode](irc-mode.md) | `M-x irc` | Built-in rcirc-style IRC servers, channels, and direct messages |

## Writing, notes, and reading

| Mode | Open with | Covers |
| --- | --- | --- |
| [morg-mode](morg-mode.md) | Open any `.md` file, `C-c A` | Rendered Markdown, folding, runnable fenced blocks, inline `C-RET` AI replies, narrowing, and agenda |
| [writing-mode](writing-mode.md) | `M-x write`, `M-x writing-mode`, `C-c ! a` | Distraction-free writing layout, word count, and anchored margin annotations |
| [pdf-reader-mode](pdf-reader-mode.md) | `M-x pdf-open` | Rendered PDF reading, themes, zoom, and non-destructive page editing |

## Files, buffers, and navigation

| Mode | Open with | Covers |
| --- | --- | --- |
| [dired-mode](dired-mode.md) | `C-x d`, `C-x p d` | Directory tables, Git status, marking, filtering, bulk actions, and editable filenames (`wdired-mode`) |
| [ibuffer-mode](ibuffer-mode.md) | `C-x C-b`, `M-x groups` | Buffer management tables, Emacs-style filters, and task group management (`groups-mode`) |
| [browse-mode](browse-mode.md) | `M-x browse`, `M-x browsers` | Clean web page reading, XSLT site parsers, and live Chrome window/tab control |
| [editing-modes](editing-modes.md) | `M-x cua-mode`, `M-x evil-mode`, `M-x visual-line-mode` | Shift selection (`cua-mode`), optional Vim modal editing (`evil-mode`), and soft wrap |

## Code and projects

| Mode | Open with | Covers |
| --- | --- | --- |
| [code-mode](code-mode.md) | `M-x code-mode`, `M-x workspace-manage` | Isolated agent coding workspaces, Git worktrees, and interactive diff review (`diff-mode`) |
| [prog-mode](prog-mode.md) | Open any source file, `M-x code-browse` | Tree-sitter languages, structural browsing, `tree-edit-mode`, `lsp-mode`, and `occur-ts-mode` |
| [buffer-log-mode](buffer-log-mode.md) | `C-x v l`, `M-x buffer-log` | Buffer provenance: every accepted revision with actor, operation, and diff |
| [term-mode](term-mode.md) | `M-x term`, `M-x shell`, `M-x repl`, `M-x tail-file` | Raw PTY terminals, comint shells, live file tailing, and the live Scheme REPL |

## Tasks and automation

| Mode | Open with | Covers |
| --- | --- | --- |
| [todo-mode](todo-mode.md) | `C-x t`, `M-x todo` | Shared human/agent todo list, status tabs, filters, sub-tasks, and task detail pages |
| [events-mode](events-mode.md) | `M-x events`, `M-x cron-list`, `M-x webhooks` | Live event bus log, scheduled cron jobs, HTTP webhooks, and reactive workflows |

## System and customization

| Mode | Open with | Covers |
| --- | --- | --- |
| [packages-mode](packages-mode.md) | `M-x packages`, `M-x app-registry` | Installing, updating, holding, rolling back, loading/unloading packages, and browsing apps |
| [keys-mode](keys-mode.md) | `C-h B`, `C-h e` | Keymap precedence, live key rebinding (`keys-mode`), and filtered editor logs (`messages-mode`) |
