# ai-mode and llm-connectors-mode

compos offers two related apps for managing models, presets, prompt sections, and connectors:

- `M-x ai` (`ai-mode`): unified tabbed workspace for chat, group, and global LLM settings, presets, prompts, connectors, and local models.
- `M-x llm-connectors` (`llm-connectors-mode`): dedicated app for installing, signing in to, testing, and benchmarking every agent, API, and browser connector.

## `ai-mode` (`M-x ai`)

Use `<left>` and `<right>` to switch tabs. Every key works both on the list and on the detail page beside it.

| Tab | What it manages | Key actions |
| --- | --- | --- |
| `chat` | Current chat config | `b` backend, `m` model, `e` effort, `u` toggle tool/MCP, `p` apply preset, `s` save as preset, `U` update preset, `G` set group default, `A` set global default |
| `group` | Current group's default | `b`, `m`, `e`, `u`, `p`, and `c` to clear group override |
| `global` | Compos-wide default | `b`, `m`, `e`, `u`, `p` |
| `presets` | Saved bundles | `a` apply to chat, `G` group default, `A` global default |
| `prompts` | System prompt sections | `o` toggle section on/off in this chat, `v` edit the source file |
| `connectors` | Model connectors | `t` test and time, `i` install, `l` sign in, `k` set API key, `d` set default, `P` open in `llm-connectors` |
| `models` | Local and hosted model hosts | `x` load model, `i` install, `D` uninstall |

Press `g` to refresh, `/` to narrow, and `q` to quit.

## `llm-connectors-mode` (`M-x llm-connectors`)

Shows every connector grouped under agent (ACP), API, and browser sections, along with readiness and last test latency.

| Key | What it does |
| --- | --- |
| `i` | Install the connector's CLI in a terminal buffer |
| `l` | Run the connector's login command in a terminal |
| `k` | Add or update an API key |
| `t` | Send a live test prompt and record reply and latency |
| `T` | Test all ready connectors in parallel |
| `d` | Make the connector (or model row) the default for new chats |
| `a` | Add a custom OpenAI-compatible endpoint or hosted provider |
| `RET` | Open the connector's detail page and full last test output |
| `M-o` | On a connector page, open a debugging chat preloaded with the last failure |
| `g` / `/` / `q` | Re-scan, narrow, or quit |

See also: [SETUP.md](../../SETUP.md), [08. MODELS + CONNECTORS](../08.%20MODELS%20+%20CONNECTORS.md).
