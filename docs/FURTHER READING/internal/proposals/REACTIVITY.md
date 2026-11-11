# Reactivity - a possible approach.

We already have file auto-revert mode. instead of 'file', we use urls. when those urls update we auto-revert the file. a dom diff library will handle the hard parts. does this work?



Yes, mostly. The model fits: a URL is a file that someone else edits, and `auto-revert-mode` already has the right rules (only revert unmodified buffers, keep point, run quietly). There are three gaps:

**1. URLs do not tell you when they change.**
A file watch gets an event. A URL does not. You need a change source for each buffer:
- **Default: poll with conditional GET.** Use `ETag` / `If-None-Match` or `Last-Modified`. A page that has not changed costs one 304 reply and no parse. Run the poll on its own lane at the interval the buffer names, the same pattern as the Spotify poll.
- **Use push when it exists:** SSE, websocket, a feed, or a webhook. Then the update arrives at once and no poll runs.

So the mode should be "auto-revert with a pluggable change source", not "auto-revert on a timer".

**2. Diff what the user sees, not only the DOM.**
The buffer holds the text after the XSLT parser has run, not the HTML. Use the two diffs for different jobs:
- **DOM diff:** decides *whether* a real change happened. It can ignore noise such as timestamps, CSRF tokens, ad slots and "3 minutes ago" labels. Without this filter, most pages look changed on every poll, and the buffer churns.
- **Text diff on the parsed output:** decides *what to apply*. Apply small edits, not a whole new text. Small edits keep point, marks, folds and annotations in the regions that did not change. A whole-text revert loses them.

**3. Some pages cannot come from a plain fetch.**
- **Pages built by JS, or behind a login:** these need `browser-snapshot` through the user's Chrome. That is heavier, so give them a slower interval.
- **Rate limits and politeness:** use backoff on errors and a minimum interval for each host.

**Verdict:** it works, with one limit. Polling gives eventual freshness, not true reactivity. The delay is the poll interval, unless the source can push. If you build one mode that takes a change source (poll, conditional GET, push or Chrome) plus a noise filter for each host, you get one mechanism for every case. You could keep that filter next to the site parser.

> what about databases and whatsapp and so on? that's why the webhooks were invented. is there a smarter way to notify a system? 


Yes. Webhooks are one answer, but they are not the best one for an editor. The better pattern is **a log with a cursor**.

**Why webhooks are a weak fit for compos**
- **They need a public URL.** The editor runs on a laptop behind NAT, so it has no public address. You would need a relay or a tunnel.
- **They lose events.** If the editor is asleep or offline when an event comes, it misses that event. You must then add retries, deduplication and a resync.
- **Each one is a new endpoint** to secure, with signatures and secrets.

**The better pattern: subscribe with a cursor**
The source keeps an ordered log of changes, and the consumer keeps a cursor into it. The consumer asks "what changed since cursor X?" and the call blocks until something changes, or it comes back at once if changes are already waiting.
- You get push latency, because a blocking call returns the moment a change happens.
- You lose nothing when offline. On reconnect, you continue from the cursor.
- Only the client makes outbound connections, so it needs no public URL.

Many systems already work this way:

| Source | Mechanism |
|---|---|
| Postgres | `LISTEN/NOTIFY` for the signal; logical replication (LSN = cursor) for the data |
| MySQL, Mongo | binlog / change streams (resume token) |
| CouchDB, Firebase | `_changes` feed with `since` |
| Kafka, NATS, Redis Streams | consumer offsets |
| Mail | IMAP `IDLE` + `CONDSTORE`/`MODSEQ` |
| Matrix, Telegram | `/sync?since=` and `getUpdates` long-poll |
| WhatsApp | a persistent socket. The Business API uses webhooks, so use a bridge (whatsmeow or a Matrix bridge) that holds the socket and gives you a log |
| Plain web | conditional GET, which is the weakest case |

**What this means for the proposal**
The "pluggable change source" becomes one interface: `(subscribe SOURCE CURSOR on-change)`. Each adapter maps a system's own mechanism onto that interface. Where only webhooks exist, a small relay receives them and adds them to a log, and compos reads that log the same way as every other source. The buffer side does not change: auto-revert applies a diff when an event comes, and stores the cursor so the next session continues from that point.

In short, webhooks become one adapter. The core is cursor plus subscription.

> we have some prior art?

Yes. Most of the pieces already exist. They just are not connected to buffers yet.

**The log with a cursor**
- **Event log:** a durable log of events. Each event has a seq, a topic and data. You publish with `event-publish!` and read with `event-log-read`, which gives you the events after a given seq.
- **Subscriber cursors:** `event-log-position` and `event-log-position-set!` save the last seq that each named subscriber took. So a consumer that restarts continues from where it stopped. This is the cursor pattern from my last answer.
- **`events-mode`:** a buffer that lists the log and updates while it is on screen.

**Sources that already add to the log**
- **WhatsApp:** `whatsapp-feed-start` uses a bridge with two paths. The bridge calls a webhook for push, and a sweep reads the bridge's REST server every `whatsapp-feed-sweep-seconds`. The sweep catches anything the webhook missed.
- **Mail:** `mail-feed-start` works the same way, with a webhook plus a sweep.
- **Webhooks in general:** `define-webhook!` turns each request into a `webhook:NAME` event. `webhook-attach-workflow!` runs a handler on those events. The server listens on the tailnet, which takes care of the "no public URL" problem.
- **Feeds:** RSS and Atom subscriptions, refetched on request.
- **Polls:** `run-on-lane!` runs a poll on its own lane, as the Spotify poll does.

**The buffer side**
- **`autorevert`:** keeps the text the buffer last agreed on with its file (`auto-revert-base`). It then merges the outside changes with the buffer's own changes (`auto-revert-merge!`), so it does not replace the whole text. This is the "apply small edits" part.

**The gap**
`autorevert` only follows files on disk. To fill the gap, let a buffer subscribe to an event-log topic with a saved cursor. When an event comes, the buffer gets the new text and runs it through the same base-and-merge path. Then the WhatsApp/mail pattern (webhook for speed, sweep so nothing is lost) becomes the standard change source for every kind of source, URLs included.

> and the ambient page dancing to the music? we also already have a notification framework.

That gives three kinds of source, and only one of them is new. All three ride the event bus (`docs/EVENT BUS.md`). They differ in how often they fire and in what reacts.

| Kind | Example | Bus tier | What reacts | State |
|---|---|---|---|---|
| **Events** | a WhatsApp message, a mail | durable: the SQLite log, a year, exactly once | workflows, and `notify!` | exists |
| **Documents** | a URL, a database row | short: a `changed` event, kept days | a buffer that follows the topic, through autorevert's base-and-merge | the gap above |
| **Signals** | audio levels, 60 a second | hot: in memory, the latest value only | page variables (CSS custom properties) on the components that ask for them | new |

**Events are done.** Mail and WhatsApp are feeds (a webhook plus a sweep). They write to the log. `notify!` (`notifications.scm`) puts a notice under `notify:SOURCE`, and a bus subscriber shows it in the corner. `mail-notify` and `whatsapp-notify` turn the notices on and off. Workflows react exactly once. Reactivity adds nothing here, except `define-feed` and the feed heartbeat that the bus document already lists under Not yet.

**Documents** are the auto-revert idea above: the source publishes `changed` under its topic, and a buffer that follows the topic applies the new text through autorevert's base-and-merge path. A followed buffer is a subscriber with a saved cursor, the same pattern `notifications.scm` uses.

**Signals cannot take either path.** A frame of audio levels is stale after 20 ms. If you log it, notify on it or re-render a buffer for it, the frames queue up on the Scheme lane. Every buffer and keystroke then waits behind them, and the page still reacts late. A signal needs its own path:
- **Source:** a feed like any other, started and stopped from Scheme. It does not write to the log. Elixir keeps the latest value of each signal topic in the hot tier.
- **Delivery:** the page subscribes to the signal topics that its components name. Elixir pushes the latest values over the LiveView socket at the screen's frame rate, and drops a frame when a newer one has already arrived. A small client hook sets them as CSS custom properties on the elements that asked for them. Nothing re-renders, and nothing runs on the Scheme lane.
- **Binding:** a component asks for signals in its props, for example `'signals '(("audio:system" bass --sp-bass) ("audio:system" level --sp-level))`. The CSS decides what a value means: a scale, a brightness or a blur. Scheme owns the policy, and Elixir and the client hook only carry numbers.

This is the one place where reactivity needs new Elixir and JS: the hot tier, the push over the socket, and the hook. Everything else is Scheme on the existing bus.

**The worked example: the ambient page dancing**
- **Source:** `cava` (Homebrew, MIT). With `source = tap` (macOS 14.2+), it reads the system output through a Core Audio tap. It needs no loopback device. In raw mode it writes levels to a named pipe. To get the macOS audio-recording permission, `cava` must be started by launchd (`launchctl submit`), so it is responsible for itself. Grant the permission to the real binary path. A Homebrew upgrade changes that path, so the permission must be granted again.
- **Feed:** `audio:system`. Elixir reads the pipe and turns each frame into `bass` and `level`. Mono mode puts the bass in the first bar.
- **Control:** the ambient page has its own keymap (`anchor-keymap`). Its `a` key starts and stops the feed. The feed also stops when the page leaves the screen or the music pauses.
- **Look:** the photo kicks on `--sp-bass` and breathes with `--sp-level`. The facts do not move.

**Not yet**
- The hot tier, the signal push over the socket, and the client hook.
- `define-feed` with heartbeats, which documents and signals share with events.
- Followed buffers: the subscriber with a cursor that feeds autorevert's merge.
- A noise filter for each host, kept next to its site parser.
