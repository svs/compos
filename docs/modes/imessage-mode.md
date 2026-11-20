# iMessage and SMS (macOS)

The bundled `imessage` package reads your local macOS Messages database (`~/Library/Messages/chat.db`), sends replies through Messages, and extracts recent one-time verification codes.

## Setup (macOS only)

1. Load the package in `~/.compos/init.scm` (it is bundled but opt-in):

   ```scheme
   (require 'imessage)
   ```

2. Grant **Full Disk Access** in macOS System Settings -> Privacy & Security -> Full Disk Access to compos (or the terminal app that launches the daemon) so it can read `~/Library/Messages/chat.db`.
3. Enable **Text Message Forwarding** on your iPhone if you also want SMS messages.

## Commands and keys

| Command | What it does |
| --- | --- |
| `M-x imessage` | Open the iMessage workspace |
| `M-x imessage-list` | Show the recent chat list |
| `M-x imessage-reply` | Reply to the selected conversation |
| `M-x otp` | Copy the newest one-time verification code from Messages (checks the last `otp-minutes`, default 15) |

Inside the list: `RET` opens a conversation, `r` sends a reply, `/` narrows, `g` refreshes, and `q` quits.

See also: [whatsapp-mode](whatsapp-mode.md), [telegram-mode](telegram-mode.md), [11. CONNECTED APPS](../11.%20CONNECTED%20APPS.md).
