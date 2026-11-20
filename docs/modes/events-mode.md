# events-mode, cron-mode, and webhooks-mode

compos routes background activity -- incoming messages, finished agent turns, cron ticks, and HTTP requests -- through one event bus so workflows and reactive agent listeners can act automatically.

## `events-mode` (`M-x events`)

Live view of the newest events across every topic, updating as events arrive.

| Key | What it does |
| --- | --- |
| `RET` | Show full event payload beside the list |
| `t` / `T` | Filter to one topic family (for example `mail` or `whatsapp`) / show all topics |
| `/` | Pick a topic tab or narrow by text |
| `g` / `q` | Refresh or quit |

## `cron-mode` (`M-x cron-list`)

Lists scheduled jobs defined via `(cron-define! NAME SPEC ACTIONS...)` (persisted in `~/.compos/cron.scm`), showing schedule, next run, and last run.

- `r`: run the job immediately.
- `k`: remove the job.
- `/` / `g` / `q`: narrow, refresh, or quit.

## `webhooks-mode` (`M-x webhooks`)

Lists local HTTP webhook endpoints (`/hooks/NAME`, default `127.0.0.1:4791`).

| Key | What it does |
| --- | --- |
| `c` / `e` / `k` | Create, edit, or remove an endpoint |
| `w` / `W` | Attach or detach a workflow handler |
| `p` | Toggle public tunnel access vs localhost only |
| `y` | Copy the webhook URL |
| `h` | Open this endpoint's requests in `events-mode` |
| `s` | Start or stop the webhook server |
| `/` / `g` / `q` | Narrow, refresh, or quit |

See also: [09. TODOS + WORKFLOWS](../09.%20TODOS%20+%20WORKFLOWS.md), [EVENT BUS](../FURTHER%20READING/EVENT%20BUS.md).
