# Mail: notmuch-mode, notmuch-hello-mode, notmuch-show-mode, mail-compose-mode

compos treats mail as a first-class workspace: `M-x mail` opens your index, the active thread, and a companion agent chat side by side. The same UI works over a local `notmuch` database, a remote `notmuch` host over SSH, or directly against the Gmail API.

## Open

- `M-x mail`: open the three-pane mail workspace (index, thread, and chat).
- `M-x notmuch`: open `notmuch-hello-mode` (saved searches and tag counts).
- `M-x notmuch-inbox`: jump straight to your default inbox query.
- `M-x notmuch-search`: run any notmuch search query.
- `M-x notmuch-switch-host`: switch between configured accounts and backends.

## Three ways to connect email

| Path | Best for | Setup |
| --- | --- | --- |
| **Direct Gmail API** | Fastest Gmail/Workspace setup (no local sync) | Run `M-x google-connect` with a Desktop OAuth client at `~/.compos/google-client.json`, add `(gmail "you@example.com")` to `notmuch-mailboxes`, and add `"gmail:you@example.com"` to `mail-feed-profiles` (polls every `mail-feed-gmail-seconds`, default 5s). |
| **`notmuch` + `lieer` (`gmi`)** | Fast offline Gmail search and two-way label sync | Install `notmuch` and `lieer`. Use one notmuch profile per account (`~/.config/notmuch/PROFILE/config`) and route sending through `gmi send -t -C FOLDER` in `notmuch-send-routes`. Avoids IMAP duplicate messages. |
| **`notmuch` + `mbsync` + `msmtp`** | Non-Gmail IMAP providers | Sync maildir with `mbsync`, index with `notmuch new`, and send via `msmtp -t` (the default) or `notmuch-send-routes`. |

Google OAuth note: create the Desktop OAuth client inside a Google Cloud project belonging to the account's own organization. Using another organization's Internal project fails with `Error 403: org_internal`.

## Keys in `notmuch-mode` (thread list)

| Key | What it does |
| --- | --- |
| `RET` / `v` | Open thread (`notmuch-show-mode`) / preview thread |
| `n` / `p` | Move down or up and preview |
| `a` / `d` | Archive / trash (tag) thread |
| `r` | Reply to thread |
| `t` | Classify using the mailbox's tags (`notmuch-autotag`) |
| `L` | File thread for an agent (`+liked -inbox`) |
| `0` | Strip all tags |
| `SPC` | Mark rows; capital action keys run on every marked thread |
| `/` / `l` / `\` | Add custom query filter / add tag filter / remove last filter |
| `s` | Start a new search |
| `g` / `q` | Refresh / pop newest filter or return to `notmuch-hello-mode` |

## Keys in `notmuch-show-mode` and `mail-compose-mode`

- In `notmuch-show-mode`: `a` archive, `L` hand to agent (`+liked -inbox`), `r` reply, `C-c a` open attachment, `v` toggle HTML vs plain text, `M-g i` jump to a message in the thread, `q` return to list.
- In `mail-compose-mode`: headers sit above the separator line and body below; `C-c C-c` sends the message, and `C-c C-k` discards the draft.
- Cleanup helpers: `M-x notmuch-unsubscribe` and `M-x notmuch-purge-sender`.

See also: [whatsapp-mode](whatsapp-mode.md), [telegram-mode](telegram-mode.md), [MAIL](../FURTHER%20READING/features/MAIL.md).
