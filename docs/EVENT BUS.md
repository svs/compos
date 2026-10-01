# The event bus

Everything that happens outside a keystroke reports to one place: a WhatsApp message came in, a mail arrived, an agent finished a turn, a model answered, a workflow ran. That place is the event log, and the things that react to it are workflows.

This document is the design: what is platform and what is application, what each guarantees, and how a workflow reads. The code is `apps/compos_core/lib/compos/core/events/log.ex`, `workflow.ex`, `workflows.ex`, `scheme/packages/events.scm` and `workflows.scm`. `scheme/packages/events-demo.scm` is a scene you can drive: `M-x events-demo`.

## Platform and application

The platform knows nothing about WhatsApp, todos or recruiting. An application is a policy plugged into it.

| Layer | What it is | Where |
|---|---|---|
| Feeds | turn an outside source into events: a push (webhook) and a sweep that adds what the log lacks | `whatsapp.scm`, `notmuch.scm` |
| The log | durable, numbered events with topics; positions; `once` keys | `events/log.ex` |
| The bus | `event-publish!`, `event-subscribe!`, views: delivery to Scheme | `events.scm` |
| Workflows | supervised consumers that run a Scheme handler exactly once per batch | `workflow.ex`, `workflows.ex`, `workflows.scm` |
| Inference | typed questions a model answers, each observed | `workflows.scm` (`yes?`, `pick`, `extract`, `ask-model`) |
| Applications | a `define-workflow!` and a handler of a few dozen lines | e.g. `events-demo.scm` |

A test for which side something is on: if the code names a source, a person or a business object, it is application.

## The log

`Compos.Core.Events.Log` is one SQLite file (`~/.compos/events.db`, WAL). An event is a seq, a topic (`whatsapp:9198…`, `mail:recruiting`, `chat:…`), a kind, data and a time. Kind and data are Scheme values and read back as they went in. A write is on disk before `append` returns. Events are kept for `:events_retain_days` (365).

Besides events the file keeps two small tables:

- **positions**: the seq a named consumer has finished. A Scheme subscriber's, and a workflow's (`workflow:NAME`).
- **once**: the value `once!` recorded under a key, for as long as the file lives.

Topics are matched by pattern: `"demo:*"` is a prefix, anything else one topic.

After each append the log sends `{:event_appended, seq, topic}` to every Elixir process registered under `:event_log` in `Compos.Core.EventRegistry`; that is how workflows wake. After a burst it also calls `events-arrived!` once, and `events.scm` hands the new events to its Scheme subscribers and views.

## Workflows

A workflow is a name, the topic patterns it listens to, a key to group by, and a Scheme handler. In Scheme:

```scheme
(define-workflow! "demo-triage"
  'listen   '("demo:wa:*" "demo:mail:*")
  'group-by 'demo-person
  'quiet    300
  'handle   'demo-triage)
```

Each one is a `Compos.Core.Workflow`: a GenServer under `Compos.Core.Workflows`, which restarts it on its own if it crashes. Its state is the log, so a restart costs nothing: it reads its position and carries on.

### A run

1. **Wake.** A matching append arms a quiet gap (`'quiet`, 300 ms). Further appends push it out, but never past `'max-wait` (2 s) from the first, so a steady stream cannot starve the workflow. The mailbox is the wake-up; the log is the record, so a lost wake-up costs latency and never an event.
2. **Read.** The events after the workflow's position, up to `'batch` (200), oldest first.
3. **Handle.** The core calls `(workflow--run NAME EVENTS)` on the workflow's own lane, `{:workflow, NAME}`, from a supervised task with a timeout (`'timeout`, 2 min). Never on `:ui`: a keystroke does not wait for a workflow. Scheme groups the events by the key and calls `(HANDLE KEY EVENTS)` once per group.
4. **Commit.** See below.
5. **Again.** If events came during the run, or the batch was full, the next run starts at once. Otherwise the workflow goes idle.

One run at a time is not a lock: a workflow is one process, and its mailbox serialises everything that reaches it.

### Exactly once

While a handler runs, `emit!` and `once!` write nothing. They collect in the lane process (`:compos_workflow_txn`). When the handler returns, `Log.commit/5` writes, in **one SQLite transaction**:

- the events the handler emitted,
- the `once` keys it recorded,
- an `obs:workflow:NAME` `run` event,
- the new position,

and only if the position still stands where the batch was read from. So:

| What happens | Result |
|---|---|
| The handler raises, times out, or the daemon dies mid-batch | nothing was written; the batch runs again |
| Someone rewinds the workflow during a run | the commit finds the position moved and writes nothing; the new range runs |
| The batch commits | its events, keys and position landed together, once |

This holds because the queue, the effects and the position are one database. It is the reason the log is not a broker.

What a handler does **outside** the log (a model call, an HTTP request, a todo file) is at least once: the call can succeed and the commit fail. An action that must not repeat is written as an event (an intent), and a second workflow carries it out keyed by `once!` and, where the far side has one, its own idempotency key. See the outbox example below.

### Failure

A failed batch is recorded as an `obs:workflow:NAME` `failed` event with the attempt and the error, and the workflow waits out a backoff: `'backoff` (1 s), doubling to `'max-backoff` (60 s), plus up to half again of jitter. After `'max-attempts` (5) the batch is **parked**: a `parked` event on `workflow:NAME` records its range and the error, and the position moves past it in the same transaction, so one poisoned batch does not hold up the ones behind it. Other workflows are unaffected throughout.

### Control

All by message to the workflow's process, and all from Scheme:

| Call | Does |
|---|---|
| `(workflow-status NAME)` | status (`idle`, `armed`, `running`, `backoff`, `paused`, `stepping`), position, head, behind, runs, handled, failed, parked, attempts, last error, how long the current run has taken |
| `(workflow-pause! NAME)` | stop after the current batch |
| `(workflow-resume! NAME)` | run again |
| `(workflow-step! NAME)` | run one batch, then pause |
| `(workflow-rewind! NAME SEQ)` | take every event after SEQ again; `once!` keeps the actions from repeating |
| `(workflow-stop! NAME)` | stop; the position stays, so defining it again resumes |
| `(workflow-names)` | the running workflows |

A daemon that booted before `Compos.Core.Workflows` existed starts it on first use (`ensure_started`); a fresh boot starts it from the application.

## Writing a workflow

A handler should read like pseudocode. It has two kinds of step, and they do not mix:

- **Inference answers questions and returns values.** `(yes? QUESTION ABOUT)`, `(pick QUESTION OPTIONS ABOUT)`, `(extract INSTRUCTIONS ABOUT FIELDS)`, `(ask-model PROMPT ABOUT)`. ABOUT is an event or text. Nothing is written by an inference step except its own observation.
- **Code acts on the values.** Plain Scheme, and every effect through `emit!` or `once!`.

Use inference only where the decision needs judgement (is this an ask? which open todo is this?). Everything that can be a rule is a rule: lookups, thresholds, routing, keys.

`yes?` and `pick` are typed: they go through `decide` (JEV, Laya, Haiku, per `decide-config!`), or to a local model when the call names one: `'model '(host "ssh:marilyn" model "qwen3:0.6b")`, an Ollama host, or an OpenAI-shaped one whose host ends `/v1`. A small local model is offered no way out in `pick`: if its answer names no option, the answer is none. `extract` is the one free-text step: it answers a list of plists.

| Call | Is |
|---|---|
| `(emit! TOPIC KIND DATA [CAUSE])` | an event; with CAUSE, it carries `cause` (CAUSE's seq) and `trace` (the first event of the chain) |
| `(once! KEY THUNK)` | THUNK's value the first time KEY is asked, and that value ever after |
| `(event-text E)`, `(event-trace E)` | what a model reads for an event; the seq that started its chain |

Give the handler and the key function as quoted names (`'demo-triage`), so a hot reload changes what runs.

## Observability

Every step is an event, so the log is also the trace:

- `obs:llm` `call`: model, host, milliseconds, tokens in and out, the prompt and the answer, and the cause and trace of what it was about. Written at once, whatever becomes of the batch, so the calls of a failed attempt are visible too.
- `obs:workflow:NAME` `run` and `failed`: events, range, milliseconds, attempt, error. A run event lands in the commit; a failure is written as it happens.
- `workflow:NAME` `parked`: the range a workflow gave up on.
- Derived events carry `cause` and `trace`, so a message, the model call that read it, the label it got and the todo it became can be read back as one chain.
- `:telemetry` `[:compos, :workflow, :run]` with duration and event count.

`events-demo` shows all of it: stat tiles, a table of the workflows, the newest events coloured by kind, the trace of any row, and a picture of the flow that steps back and forth through the log.

## Worked examples

These are the recruiting workflows the bus is for. Only the demo's run today; the rest are the shape the comms orchestrator takes.

### Turn incoming messages into todos

```scheme
(define-workflow! "comms-todos"
  'listen   '("whatsapp:*" "mail:*")
  'group-by 'party-of                    ; code: the candidate or company, by an ATS lookup
  'quiet    (seconds 60)                 ; one decision per burst
  'handle   'keep-comms-todos)

(define (keep-comms-todos party messages)
  (let ((open (open-todos-about party)))
    (for-each (lambda (ask)
                (let ((same (pick "Which open todo is this the same as?" (as-options open) ask)))
                  (if same
                      (note-todo! same ask)
                      (file-todo! party ask))))
              (extract "What does this conversation ask of us?" messages '(title why message)))
    (for-each (lambda (todo)
                (when (yes? "Do these messages finish this todo?" (todo-and messages todo))
                  (close-todo! todo)))
              open)))

(define (file-todo! party ask)
  (once! (string-append "comms-todo:" party ":" (plist-get ask 'message))
         (lambda () (emit! "todo:intent" 'file (list 'party party 'title (plist-get ask 'title))))))
```

Inference does three things here: extracting what is asked, matching it to an open todo, and deciding whether something is finished. Everything else is code. Duplicates are prevented twice over: `pick` matches a new ask to an open todo (lean to the match when unsure), and the `once!` key stops a replayed batch from filing again.

### Carry out intents: the outbox

The todo list lives in files, outside the log, so filing one is an effect that can repeat. The workflow above only emits an intent. A second, entirely deterministic workflow carries intents out:

```scheme
(define-workflow! "todo-writer"
  'listen       '("todo:intent")
  'max-attempts 8
  'handle       'write-todos)

(define (write-todos _ intents)
  (for-each (lambda (i)
              (todo-create (plist-get (plist-get i 'data) 'title)
                           (list 'project "recruiting" 'source (string-append "intent:" (number->string (plist-get i 'seq))))))
            intents))
```

`todo-create` files nothing twice for one `'source`, so a retried batch is harmless: the far side is idempotent on the key. The same shape serves every outside action: a WhatsApp send, an ATS transition, a mail. Decide in one workflow, act in another, key the action.

### Keep the ATS trail of WhatsApp

```scheme
(define-workflow! "whatsapp-trail"
  'listen   '("whatsapp:*")
  'handle   'record-on-application)

(define (record-on-application chat messages)
  (let ((candidate (candidate-by-phone (chat-phone chat))))                ; code
    (when candidate
      (let ((app (pick "Which application are these messages about?"      ; inference, only when there are two
                       (open-applications-of candidate) messages)))
        (when app
          (emit! "ats:intent" 'record-whatsapp
                 (list 'application app 'messages (map event-text messages))
                 (car messages)))))))
```

### Start sourcing when a job goes live

No inference at all: a workflow is just as good a place for a rule.

```scheme
(define-workflow! "source-on-publish"
  'listen '("ats:job:*")
  'handle 'source-new-jobs)

(define (source-new-jobs job events)
  (when (pair? (filter (lambda (e) (equal? (plist-get e 'kind) 'published)) events))
    (once! (string-append "sourced:" job)
           (lambda () (emit! "sourcing:intent" 'run (list 'job job))))))
```

## Feeds

A feed guarantees that nothing outside is missed: a push path (the feed webhook, `event-feed-route!`) and a sweep that reads the source again from its last message and adds what the log lacks, skipping ids it already holds. WhatsApp and each mail profile are feeds today. Their sweeps reschedule themselves, and on 30 Sep both stopped at the same moment; a feed needs a heartbeat event and a watchdog that restarts a silent sweep. That and a shared `define-feed` are the next platform pieces.

## One bus, several tiers

Everything should publish through one API and one topic scheme, but not into one storage: volumes differ by orders of magnitude, and a keystroke must never wait on a disk.

| Tier | Holds | Storage | Workflows |
|---|---|---|---|
| durable | domain events: messages, mail, intents, what workflows emit; positions; once keys | the SQLite log, a year | yes, exactly once |
| short | `*Messages*`, `obs:*` | the same log, days | yes |
| hot | telemetry, per keystroke | an ETS ring, minutes; rollups go to the short tier | no |

`messages-watch!` then becomes a subscriber, and a second ad-hoc bus goes away.

## Backends

The log should be a behaviour (`append`, `read_any`, `commit`, `once`, positions, notices), with SQLite the default. A backend declares its guarantee:

- **SQLite**: events, once keys and position in one transaction: exactly once.
- **RabbitMQ, NATS JetStream, Kafka**: the offset and the effects cannot share a transaction: at least once, with `once!` keys removing the repeats.

The workflow code is the same either way; only the guarantee changes, and `workflow-status` should say which. Before a second backend, a bridge: a workflow that forwards chosen topics to a broker, and a Broadway producer that brings a broker's messages into the local log. Other machines join through the broker while local processing stays exactly once.

## Lists that follow a stream

The demo needed two things every live list needs, so they are list options now (`tabulated-list.scm`):

- `'follow-head #t`: a window on the top row stays on the newest row as rows arrive, scrolled to the top so the head stays in sight; a window on any other row keeps its row.
- `'panel FN`: lines above the table's own head, which keep the column titles (a mode's `'header` replaces them).

`ui/table`, `ui/stat` and `ui/stats` (`components.scm`) draw a panel with components instead of text. A list that redraws often should draw off the lane, as `events-demo` does: a task reads the log into a snapshot and writes the buffers, which serialise their own writes.

## Not yet

- Feed heartbeats and the sweep watchdog; `define-feed`.
- The backend behaviour; the broker bridge.
- The short and hot tiers; `*Messages*` and telemetry on the bus.
- `M-x workflows`: a list of every workflow with pause, step and rewind on keys. The demo shows status but drives only failure and replay.
- The comms orchestrator itself (the first worked example), with its ATS lookups.
