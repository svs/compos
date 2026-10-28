# Agent context management

An agent's context is what it knows and what it can reach when it starts work: its tools, its system prompt, and what discovery (`apropos`) shows it first. Three layers decide that, and each has one job.

| Layer | What it is | Where it lives |
|---|---|---|
| **Preset** | One capability: MCP servers, the prompt that says how to use them, and the names apropos ranks first | `~/.compos/ai-config.scm` |
| **Bundle** | A reusable chat setup: connector, model, effort, permissions, a list of presets, disabled prompt sections | the editor's saved state (desktop) |
| **Group** | A place: directory, skills, layout, todos, and which bundle its new chats start with | the group's `group.scm` |

A preset belongs to no group. A bundle can be used by any number of groups. Only what is specific to one place lives in the group.

## Presets

A preset is more than a list of MCP servers. Holding a preset, rather than the servers alone, gives a chat three things: the servers' tools, a prompt section on how to use them, and discovery that leads with the preset's own code and skills.

```scheme
(define-preset! 'recruiting
  "Recruiting: transcripts, WhatsApp, ATS"
  '(fireflies whatsapp ats-ash)
  "Every recurring job has a skill. Run (apropos \"WHAT\") first ..."
  'focus '("ats" "whatsapp"))
```

- **SERVERS** are the MCP servers the chat connects to.
- **PROMPT** (optional) becomes a system-prompt section named `preset:NAME` in every chat holding the preset.
- **`'focus`** (optional) lists the names apropos ranks first for that chat. It defaults to the preset's own name, so `ats` lifts `ats-` functions. `compos` adds no focus.

Redefining a preset without PROMPT or `'focus` keeps the values it had.

### Calls

| Call | What it does |
|---|---|
| `(define-preset! 'NAME DESC SERVERS [PROMPT] ['focus NAMES])` | define or replace a preset |
| `(preset-prompt! 'NAME TEXT)` | set only a preset's prompt |
| `(preset-get 'NAME 'KEY)` | read `description`, `servers`, `prompt` or `focus` |
| `(preset-prompt-parts PRESETS)` | the `(NAME TEXT)` sections a list of presets brings |
| `(preset-focus PRESETS)` | the names apropos ranks first for those presets |
| `(chat-presets-of BUF)` | the presets a chat holds |
| `(chat-presets-set! BUF NAMES)` | set a chat's whole preset list; `compos` is always kept |
| `(chat-preset-toggle! BUF NAME)` | turn one preset on or off |
| `(chat-preset-candidates)` | every preset, marked `●` on or `○` off |
| `M-x llm-set-preset`, `M-x llm-unset-preset` | the same from a chat |

`define-preset!` and `preset-prompt!` refuse agents. `chat-presets-set!` refuses an agent that tries to add a preset; an agent may only drop one. Presets are defined by the user in `ai-config.scm`, which loads at startup, so a preset's section is present before any app loads.

### Discovery

`apropos` answers the calling chat's skills (its group's own and the global ones) as `kind "skill"` hits, with `(skill NAME)` as the call. It ranks, in order: the exact name, the group's own skills, hits whose name starts with, or whose package or domain is, one of the chat's preset focus names, then the rest. Nothing is hidden; focus only orders. A preset prompt can therefore say "run apropos first" and trust the answer to lead with that preset's code and skills.

## Bundles

A bundle is a whole chat config, saved under a name and a shortcut key:

```scheme
(key "a" name "RECRUITING"
 presets (cloudflare fireflies postmark exa whatsapp ats stripe compos recruiting)
 connector "claude-code" model "claude-opus-5-5[1m]" effort "default"
 permission "auto" agent-mode "default" prompt-disabled () sandbox "group")
```

`prompt-disabled` lists the prompt sections the bundle leaves out (see below). A bundle keeps the key it got on its first save through updates, reordering and restarts.

### In `C-c b` (`llm-configure`)

| Key or command | What it does |
|---|---|
| `p` (`llm-config-pick-preset`) | turn presets on or off; the picker lists **Presets** first, then **MCP servers** |
| `+`, then `i` | prompt sections as switches; `x` applies, `a` all, `n` none, `C-g` discards |
| `llm-config-save-bundle` | save this config as a new bundle |
| `llm-config-save-into` | update an existing bundle with this config |
| `llm-config-use-bundle` | switch to a saved bundle |
| `llm-config-forget-bundle` | delete a bundle |
| `llm-config-new-preset` | a new bundle from backend, model and effort |

### Which bundle a new chat gets

`llm-default-bundle-apply!` runs when a chat is made. It uses the group's `'llm` setting, else `llm-default-bundle`, else nothing.

| Call | What it does |
|---|---|
| `(group-llm! GROUP BUNDLE)` | make BUNDLE (a name or a config) what GROUP's new chats start with; `#f` resets |
| `M-x group-llm` | the same, interactively |
| `(llm-group-bundle GROUP)` | the bundle a group resolves to |
| `llm-default-bundle` | the global default for groups that name none |
| `(group-defaults! 'llm BUNDLE ...)` | in `group.scm`, the same setting from the group's file |

Bundles persist with the desktop. A change is live at once but reaches disk at the editor's next desktop save. Changing a bundle affects new chats; open chats keep their presets.

## How the system prompt is collated

The prompt is a list of named sections, joined in order by `prompt-parts-text`. Each section comes from one source:

1. **Prompt files.** Each `FILE.md` in `prompts-directories` (default `priv/prompts/`) is a section named `FILE`. The defaults keep a fixed order: `identity`, `quiet-editor`, `scope`, `chat-context`, `scheme`, `discovery`, `reading`, `repository`, `browser`, `components`. Other files follow by name. An earlier directory wins a name, so a user directory overrides a default file.
2. **Generated sections:** `catalog`, `recipes`, `mcp` (the servers the chat holds), and `skills` when it has text.
3. **Preset sections:** `preset:NAME`, one per preset the chat holds that has a prompt, right after `mcp`.
4. **Buffer parts:** sections a mode or package set on this chat with `prompt-part-set!`, such as `chat-preamble`, `code`, `todo` and `code-agent`.

Names are unique. The last fragment of a name wins, in the place the name first took, so a buffer part replaces a prompt file of the same name.

Last, the chat's `prompt-disabled-parts` (seeded from its bundle's `prompt-disabled`) removes the sections switched off. A name that no longer exists switches nothing off.

### Lanes and freezing

- **Direct API chats.** `chat-system-prompt-parts` gives the sections; `chat-thread-context` joins them into the request's `system` field. The first send freezes them in `chat-prompt-snapshot`, and later turns reuse it so the cache holds.
- **ACP sessions (Claude Code and others).** `agent-system-prompt-parts` gives the same sections, appended through `_meta.systemPrompt.append` when the session starts. They are fixed for that session; a connector or preset change restarts or reattaches it.

Both lanes must say the same thing. A prompt change is checked on the direct lane, the ACP lane and the inline `M-o` path.

The system prompt holds no live workspace state. Group members, visible buffers and the like come from `(chat-context)` at the start of a task, so they never change the prompt bytes.

### Inspecting

| Call | What it shows |
|---|---|
| `M-x chat-show-prompt` | lane, lifecycle, ordered sections with `●`/`○`, byte counts, and the final text |
| `(chat-prompt-report BUF)` | the same as markdown |
| `(chat-prompt-source-parts BUF)` | live sections before filtering |
| `(chat-prompt-parts BUF)` | current sections for the chat's lane |
| `(chat-system-prompt-parts BUF)` | direct-lane sections in send order |
| `(agent-system-prompt-parts BUF)` | ACP sections in session-start order |
| `(prompt-buffer-parts BUF)` | the parts modes added to this chat |
| `(prompt-files)` | every prompt file as `(NAME PATH)` |

## Injecting custom prompts

Pick the place by what the guidance is about.

| Guidance about | Put it in | Reaches |
|---|---|---|
| a capability (an MCP server, a site's Scheme) | a preset's PROMPT | every chat holding the preset, in any group |
| a feature package | `prompt-part-set!` from `chat-mode-hook` | every chat |
| one chat | `prompt-part-set!` on that buffer | that chat |
| standing editor-wide policy | a file in a `prompts-directories` directory | every chat |
| a recurring job's procedure | a skill, found through apropos | chats whose group or global skills hold it |

### A preset prompt

In `~/.compos/ai-config.scm`:

```scheme
(define-preset! 'ats "ATS" '(ats-ash)
  "Before an ats-ash tool, run (apropos \"WHAT\"). If an ats- function does it, call that.")
```

### A package section

```scheme
(define (todo--chat-mode-hook!)
  (prompt-part-set! (current-buffer) "todo" todo-prompt))

(add-hook! 'chat-mode-hook 'todo--chat-mode-hook!)

(for-each (lambda (b)
            (when (chat-buffer? b)
              (prompt-part-set! b "todo" todo-prompt)))
          (buffer-list))
```

The loop covers chats that were open before the package loaded. `(prompt-part-remove! BUF NAME)` takes a section out.

### A prompt file

```scheme
(add-to-list! 'prompts-directories "~/my-prompts")
```

Each `~/my-prompts/NAME.md` is a section `NAME`; a name that matches a default file replaces it.

### Switching sections per project or group

A project's `compos.scm`, or a `group-on-chat` hook in `group.scm`, runs with the chat current:

```scheme
(prompt-section-off! (current-buffer) "todo")
(prompt-section-on! (current-buffer) "todo")
```

This sets the same `prompt-disabled-parts` that `C-c b` sets, persists with the chat, and applies at composition, so order of loading doesn't matter.

### When changes take effect

- **New chats** get them at once.
- **A direct chat** that has sent its first turn keeps its frozen prompt; **an ACP session** keeps the prompt it started with. `M-x chat-refresh-prompt` (or `(chat-refresh-prompt! BUF)`) rebuilds from current sources. It breaks the direct cache on purpose and reconnects an idle ACP session now, a busy one at its next turn.

See `docs/PROMPTS.md` for the composition contract and its change checklist.
