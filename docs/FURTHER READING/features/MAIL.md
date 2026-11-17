# Mail

Mail in compos is the notmuch package. Its mailboxes are of two kinds. A notmuch mailbox is a notmuch index that compos reads, shows, tags, answers and sends from; a sync tool fills it, and it can live on this machine or on another one. A Gmail mailbox reads a Google account directly through the Gmail API (see [Gmail through the Gmail API](#gmail-through-the-gmail-api)).

## The preferred setup for Gmail

A Gmail or Google Workspace account uses three parts.

1. **Google OAuth in the browser.** `M-x google-connect` opens Google's consent page in the user's Chrome. The agent drives the flow, and the user types the password and approves on Google's page. No password or app password passes through compos.
2. **notmuch and lieer.** lieer (`gmi`) syncs the mailbox into notmuch over the Gmail API.
3. **Immediate mail notifications.** New mail reaches the index and raises a notice as soon as Gmail has it. A sync on a timer is not enough.

### Sign in

The sign-in needs a **Desktop app** OAuth client. Put its JSON at `google-client-file` (`~/.compos/google-client.json`).

- Make the client in a Google Cloud project that belongs to the account's own organization.
- A client from another organization's Internal project fails with `Error 403: org_internal`.
- In a Workspace organization, make the consent screen Internal. Then the organization's accounts can sign in, and Google needs no app verification.
- Enable the Gmail API in the project.

The agent can make the client in the Cloud Console in the user's Chrome, in the profile signed into the account. The Chrome extension must run in that profile, and `M-x browsers` lists the profiles it reaches.

Details: [GOOGLE](GOOGLE.md).

### Why lieer, not IMAP

lieer is made for notmuch: it reads and writes the notmuch database directly.

- Each message comes down once. IMAP turns labels into folders, so a message with three labels comes down three times.
- Gmail labels become notmuch tags: `INBOX` is `inbox`, and `UNREAD` is `unread`.
- A tag change in notmuch goes back to Gmail as a label change, and a label change in Gmail comes down as a tag change. Archiving in compos archives in Gmail.
- `gmi send` sends through Gmail, so the sent mail is in Gmail's Sent.
- It uses the same OAuth client, so it needs no app password.

Use IMAP (mbsync) for a provider that is not Gmail.

### One mailbox, one notmuch profile

Each account has its own notmuch profile, `~/.config/notmuch/PROFILE/config`, and its own database. Run `gmi` in the account's folder with `NOTMUCH_PROFILE=PROFILE`. Set `new.tags` to `new`, so the mail feed and autotag can find what came in.

### Where the mail lives

notmuch searches only mail on the machine it runs on. The machine can be the laptop or a server.

- **The laptop.** Search is fastest and works offline. The sync runs only while the laptop is awake.
- **A server.** The mail stays off the laptop and syncs while the laptop sleeps. Add `(HOST PROFILE)` to `notmuch-mailboxes`; every notmuch call then runs over ssh. `notmuch-switch-host` changes the mailbox.

## Gmail through the Gmail API

A mailbox can also read a Gmail account directly, with no lieer and no notmuch index. Add `(gmail "ADDRESS")` to `notmuch-mailboxes` for an account that `M-x google-connect` connected, and choose it with `notmuch-switch-host`. The mail UI is the same: the index, the thread view, tagging, replies and sending.

- **Tags are labels.** `inbox`, `unread`, `sent`, `draft`, `spam`, `trash`, `flagged` and `important` are Gmail's own labels, and `promotions`, `social`, `forums` and `updates` are its categories, so `mail-notify-skip-tags` keeps them quiet. Any other tag is a user label of that name, which Gmail gets the first time a thread is given it.
- **Searches are notmuch queries.** `tag:`, `from:`, `to:`, `subject:`, `id:`, `date:`, `and`, `or`, `not` and parentheses become Gmail search. `thread:ID` picks threads by id. Gmail has no form for `lastmod:`, `folder:` or a regex tag, so a search drops them.
- **Sending.** Mail whose From is the account's address goes out through Gmail, so it lands in Sent, and a reply joins the thread it answers. Other mail still goes through `notmuch-send-routes`.
- **Counts are Gmail's estimates.** They are close, not exact.
- **Blocking a sender** makes a Gmail filter. That needs the `gmail.settings.basic` scope, which `google-connect` does not ask for yet. Without it, the sender's mail is still trashed, but the mail that comes later is not.

A notmuch mailbox and a Gmail one are two backends of the same UI. `mail.scm` is the UI, `notmuch.scm` the notmuch backend and `mail-gmail.scm` the Gmail one. Each operation the UI uses (search, show, tag, count and the rest) is defined once per backend; `mail-backend-register!` adds a backend.

## Notifications

The mail feed turns each message the index takes into a `mail:PROFILE` event: the headers only, because the body stays in notmuch. `mail-notify` raises a notice for each inbox mail. `mail-notify-skip-tags` lists the tags that stay silent.

New mail reaches the feed in three ways:

- **Push.** The mail host's notmuch `post-new` hook posts each batch of `tag:new` to the feed webhook's `/mail`, with the profile in `x-notmuch-profile`.
- **Sweep.** Every `mail-feed-sweep-seconds`, the feed asks each mailbox what changed since its last revision, and it adds what a push dropped. A message only the sweep found is also a `feed:mail:PROFILE` event.
- **Gmail.** A profile `gmail:ADDRESS` in `mail-feed-profiles` reads that account through the Gmail API. Every `mail-feed-gmail-seconds` (5 by default), the feed asks Gmail's history what arrived since its last look, so a notice comes about five seconds after Gmail has the mail. A look with nothing new is one small request. This poll runs even when `mail-feed-enabled` is off. Its events are `mail:gmail:ADDRESS`, and a mail you send to yourself counts as received.

The feed is only as fast as the sync. lieer fetches only when it runs, so a timer for `gmi sync` delays every notice by the timer's interval. To notify at once, Gmail's push must start the sync: Gmail's `watch` sends a notice for each mailbox change through Cloud Pub/Sub. The listener then runs `gmi pull` and `notmuch new`, and the `post-new` hook posts to the feed. compos does not ship this yet. A Gmail mailbox needs no sync, so its notices come within `mail-feed-gmail-seconds`.

Settings: `mail-feed-enabled`, `mail-feed-host`, `mail-feed-profiles`, `mail-feed-sweep-seconds`, `mail-feed-gmail-seconds`. Commands: `mail-feed-start`, `mail-feed-stop`.

## Read and answer

| Command | What it does |
| --- | --- |
| `mail` | Index, thread and chat in three panes, in this group |
| `notmuch` | The mailboxes: the saved searches with counts |
| `notmuch-inbox` | The index on `notmuch-default-query` |
| `notmuch-search` | Any notmuch query |
| `notmuch-switch-host` | Another mailbox |
| `notmuch-reply`, `notmuch-show-reply` | Reply |
| `notmuch-archive-marked`, `notmuch-trash` | Archive or trash |
| `notmuch-add-tag`, `notmuch-remove-tag` | Tag |
| `notmuch-unsubscribe`, `notmuch-purge-sender` | Get rid of a sender |
| `notmuch-autotag`, `notmuch-autotag-new` | Tag threads with this mailbox's own tags, by a model |

In the list, `Enter` opens a thread, `n` and `p` move and preview, `a` archives, `d` trashes, `r` replies, `/` filters and `g` refreshes. In a draft, `C-c C-c` sends and `C-c C-k` aborts. The send command is `msmtp -t` unless `notmuch-send-routes` routes the sender elsewhere. For lieer, route the Gmail address to `gmi send -t -C FOLDER`.

## For agents

- `(notmuch ARGS)` runs the notmuch CLI with ARGS, for example `"count -- tag:inbox"`. Use it for bulk tagging by query, and to check that a change happened. It reads a notmuch mailbox only.
- `(nm--op-on MAILBOX 'OPERATION ARG ...)` runs one backend operation on any mailbox, for example `(nm--op-on '(gmail "me@example.com") 'count "tag:inbox")`. It blocks on the network, so call it from a task.
- Each new message is a `mail:PROFILE` event. To wait for a reply, use `(agent-listen! '(topic "mail:PROFILE" kind received match "SENDER") NOTE)`.
- `(google-accounts)` lists the connected Google accounts. `(google-read-api ACCOUNT "gmail" "/users/me/profile" '())` checks that Gmail answers.
