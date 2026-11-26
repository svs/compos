# Compos User Guide

Compos is a keyboard-first workspace built on the ideas of Emacs and rendered in your browser. Instead of jumping across browser tabs, terminals, mail apps, and separate AI windows, you bring your files, chats, lists, web pages, and tools into one place where the same keys and the same AI agents work on all of them.

If you have not installed compos yet, ask your coding agent to follow [SETUP.md](SETUP.md). Inside the editor, press `C-h t` for the interactive tutorial or run `M-x onboarding` for a live guided walkthrough.

## Five ideas to learn first

- **Buffer:** every piece of content is a buffer -- a file, a chat, a directory, a todo list, a web page, or a mail thread. A buffer stays alive even when no window shows it.
- **Window and pane:** the browser tab is your frame. A layout splits the frame into panes, a pane holds windows, and each window shows one buffer with its own cursor and scroll position.
- **Group:** a group holds one task -- its buffers, its window layout, its chats, and its working directory. The tabs at the top bar are your groups, and buffers never leak across groups.
- **Command and key:** every action is a named command. You can trigger the same command from a shortcut, from `M-x`, from the plain-English command palette (`s-p`), or by asking a chat agent.
- **Live customization:** compos is scripted in Scheme while it runs. Ask your agent to change a font, bind a key, or build a custom app, and the change takes effect immediately.

## Key notation and Caps Lock

This guide writes keys in standard Emacs notation:

| Notation | macOS | Linux |
| --- | --- | --- |
| `C-x` | Control + x | Ctrl + x |
| `M-x` | Option + x | Alt + x |
| `s-p` | Command + p | Super + p |
| `S-Tab` | Shift + Tab | Shift + Tab |
| `RET` | Return / Enter | Enter |
| `SPC` | Space | Space |

Two-step chords such as `C-x C-f` mean: hold Control and press `x`, then hold Control and press `f`. Sequences such as `C-h t` mean: press `C-h`, release Control, then press `t`.

Because many shortcuts start with Control, map **Caps Lock** to **Control**:

- **macOS:** System Settings -> Keyboard -> Keyboard Shortcuts -> Modifier Keys -> set Caps Lock to Control (for each keyboard).
- **Linux (GNOME):** `gsettings set org.gnome.desktop.input-sources xkb-options "['ctrl:nocaps']"`
- **Linux (X11):** `setxkbmap -option ctrl:nocaps`

If you ever feel stuck halfway through a shortcut or prompt, press `C-g` to cancel safely.

## Windows, panes, layouts, and groups

Each window keeps a stack of the buffers it showed. Opening a help page over a file and pressing `q` returns you to that exact file and line. Closing a window hides the view without deleting the buffer.

| Key | Command | What it does |
| --- | --- | --- |
| `s-<left>`, `s-<right>` | `focus-left`, `focus-right` | Move focus to the left or right window |
| `C-x o` | `other-window` | Cycle to the next window |
| `C-x 3` or `s-\` | `split-window-right` | Split side by side |
| `C-x 2` | `split-window-below` | Split top and bottom |
| `C-x 0` | `delete-window` | Close this window (buffers stay open) |
| `C-x 1` | `delete-other-windows` | Keep only this window |
| `C-c <left>`, `C-c <right>` | `winner-previous`, `winner-next` | Undo or redo window layout changes |
| `M-<down>`, `M-<up>` (or `C-M-v`) | `scroll-other-window` | Scroll the other window without leaving this one |

Choose a frame layout with `C-x l`, then press one key:

- `1`: one window
- `2`: two panes (2/3 and 1/3)
- `=`: two equal panes
- `c`: three columns (default for new groups)
- `r`: two rows
- `+`: two equal panes plus the group chat in a narrow pane
- `f`: free manual splits

Navigate buffers and groups:

| Key | Command | What it does |
| --- | --- | --- |
| `C-x b` | `ibuffer-prompt` | Switch to another buffer in this group |
| `C-x C-b` | `ibuffer` | Open the interactive list of all buffers |
| `C-x <left>`, `C-x <right>` | `previous-buffer`, `next-buffer` | Step back or forward in this window's buffer history |
| `` C-` `` | `group-next-mode-buffer` | Cycle to the next buffer of the same mode in this group |
| `C-x k` | `kill-buffer` | Kill a buffer and remove its content |
| `C-x g` | `group-switch` | Switch to another group |
| `C-x C-g n` or `s-g n` | `group-new` | Create a new empty group |

## Everyday editing and files

compos starts with `cua-mode` enabled, so Shift + arrow keys select text and your normal system Copy/Paste keys work right away. All standard Emacs editing keys also work everywhere, and Vim users can run `M-x evil-mode`.

### Files and projects

| Key | Command | What it does |
| --- | --- | --- |
| `C-x C-f` or `s-o` | `find-file` | Open a file (or create a new one) |
| `C-x 4 f` | `find-file-other-window` | Open a file in the other window |
| `C-x C-s` | `save-buffer` | Save the current buffer |
| `C-x d` | `dired` | Browse a directory |
| `C-x p f` | `project-find-file` | Find a file in the current Git project |
| `C-x p g` or `s-F` | `project-ripgrep` | Search project text with live previews |
| `C-x p d` or `s-E` | `project-dired` | Open the project root directory |
| `C-x p p` | `project-switch-project` | Switch to another project's group |

You can open remote files directly inside `C-x C-f` using `/ssh:user@host:/path/to/file`.

A file buffer automatically follows changes made on disk by git or formatters and merges them while preserving your unsaved edits.

### Search, replace, undo, and palettes

| Key | Command | What it does |
| --- | --- | --- |
| `C-s` / `C-r` | `isearch-forward` / `isearch-backward` | Search forward or backward as you type |
| `M-%` | `query-replace` | Interactive find-and-replace (`y` replace, `n` skip, `C-g` stop) |
| `C-/` or `s-z` | `undo` | Undo the last edit |
| `M-g g` | `goto-line` | Jump to a line number |
| `M-g i` or `s-i` | `imenu` | Jump to a heading or definition in this buffer |
| `M-x` | `execute-extended-command` | Run any command by name |
| `s-p` or `s-k` | `command-palette` | Find and run a command in plain English |
| `C-+`, `C-_` | `text-scale-increase` / `decrease` | Grow or shrink text in this buffer |
| `s-=`, `s--`, `s-0` | `frame-ui-scale-*` | Grow, shrink, or reset the entire UI |
| `C-M-+`, `C-M--`, `C-M-0` | `content-scale-*` | Show more or less detail in a structured buffer |

## Chats and AI agents

A chat is an ordinary buffer that lives beside your work in the same group. The agent sees your visible buffers, your group's companion buffers, and your directory automatically -- when you say "this", it knows what you are looking at.

### Everyday chat keys

| Key | Command | What it does |
| --- | --- | --- |
| `C-c c` or `C-c w` | `chat-companion` | Open or toggle between your work buffer and the group chat |
| `C-c n` | `chat-new` | Start a fresh chat in this group |
| `C-x C-c` | `chat-list` | List all live and archived chats |
| `C-c RET` | `chat-companion-ask` | Ask the group chat a question without leaving your file |
| `C-c r` | `chat-send-region` | Send the selected text to the group chat's input |
| `M-o` | `llm-companion-open` | Open a context-aware chat about the current page or buffer |
| `RET` | (in chat) | Send your message |
| `S-RET` | (in chat) | Insert a newline without sending |
| `C-RET` | (in chat) | Send ahead of queued messages (steer) |
| `C-g` | `keyboard-quit` | Stop a running reply |
| `C-c C-k` | `chat-reset` | Clear the transcript while keeping the model |
| `C-c $` | `chat-cost` | Show token usage and cost for this chat |

### Choosing connectors, models, and permissions

| Key or command | What it does |
| --- | --- |
| `C-c b` (`llm-configure`) | Configure connector, model, reasoning effort, MCP tools, and prompt sections |
| `C-c m` (`chat-set-model`) | Switch the model of this chat |
| `C-c p` (`chat-set-permission-mode`) | Cycle permission stance: `approve`, `auto`, or `ask` |
| `C-c C-y` / `C-c C-a` / `C-c C-n` | Allow once, allow always in this chat, or deny a pending tool call |
| `C-c a n` (`agent-open`) | Spawn a separate agent thread for an independent task |
| `C-c a a` (`agent-goto-attention`) | Jump to the first chat waiting on your permission or answer |
| `C-c a m` (`mcp-hub`) | Inspect or restart MCP servers |
| `M-x llm-connectors` | Install, sign in, test, and time every model connector |
| `M-x ai` | Manage chat, group, global defaults, presets, prompts, and connectors in one app |

Type `/skill-name` at the start of a chat message to run a skill, or run `M-x chat-show-skills` to browse available skills. If a turn gets orphaned after a crash, run `M-x chat-unstick` or `M-x chat-heal`.

## Communications (email, WhatsApp, Telegram, iMessage, IRC)

Bringing your messages into compos puts your inbox, chats, and AI agents in the same workspace. You can read a thread, pull in a file or issue beside it, ask an agent to draft a reply, and keep every outbound send under your approval.

- **Email (`M-x mail`, `M-x notmuch`):** opens your inbox list, active thread, and companion agent chat in three panes. Works directly over the Gmail API (`M-x google-connect`), over `notmuch` + `lieer` for fast offline Gmail search, or over `notmuch` + `mbsync`/`msmtp` for IMAP. Press `a` to archive, `r` to reply, `L` to hand a thread to an agent, and `C-c C-c` in a draft to send. See [docs/modes/notmuch-mode.md](docs/modes/notmuch-mode.md).
- **Telegram (`M-x telegram` and `telegram` bot):** supports two official-friendly paths -- a personal client (`M-x telegram`) using the shared chat input bar over an MTProto bridge, and an official `@BotFather` bot that lets you message your compos agents from your phone. See [docs/modes/telegram-mode.md](docs/modes/telegram-mode.md).
- **WhatsApp (`M-x whatsapp`):** connects through a user-chosen MCP bridge to read and reply to threads and stream incoming events. Because WhatsApp has no official personal CLI or API, unofficial Linked Devices bridges carry Terms of Service and account-ban risks as well as privacy/compliance considerations -- read [docs/modes/whatsapp-mode.md](docs/modes/whatsapp-mode.md) before connecting.
- **iMessage and SMS on macOS (`M-x imessage`, `M-x otp`):** opt in with `(require 'imessage)` and grant Full Disk Access to read and reply to macOS Messages or grab recent two-factor codes with `M-x otp`. See [docs/modes/imessage-mode.md](docs/modes/imessage-mode.md).
- **IRC (`M-x irc`):** built-in rcirc-style client with no external tools required. See [docs/modes/irc-mode.md](docs/modes/irc-mode.md).

Safety by default: when an incoming email or WhatsApp message wakes an agent chat, compos flags that chat as `untrusted?` so the agent must ask for your confirmation before sending messages, spending money, or running destructive actions.

## Working on code

compos uses tree-sitter grammars to understand source code structurally.

- **Browse by syntax tree:** run `M-x code-browse` to walk definitions with `h` (parent), `l` (child), `j`/`k` (siblings), `Tab` (fold), and `RET` or `q` to leave.
- **Jump to definitions:** press `M-g i` (`imenu`) for an outline of the current file, or `M-.` (`goto-thing-at-point`) to jump to a symbol's definition or follow a link.
- **Install grammars:** run `M-x ts-install-grammar` to add syntax colors, folding, and tree navigation for a language.
- **Build and fix errors:** run `M-x compile` in the background; press `RET` on an error line or run `M-x next-error` from any buffer.
- **Provenance:** press `C-x v l` (`buffer-log`) to view every accepted revision of a buffer along with who wrote it (you, the editor, a process, or a specific agent).
- **Task worktrees:** run `M-x code-mode` to isolate an agent coding task in its own Git worktree, and manage, diff, rebase, or land worktrees in `M-x worktree-manage`.

## Writing, Markdown, and notes

Markdown files (`.md`) open as rendered **Morg** pages -- headings, tables, images, and callouts render cleanly while your cursor edits real text.

- Press `C-c C-v` to toggle between the rendered view and raw Markdown source.
- Press `Tab` to fold a heading or code block, and `S-Tab` to cycle full-document overview folding.
- Press `C-c C-c` inside a fenced code block (`sh`, `python`, `elixir`, `node`, `scheme`, `llm`) to run it and place the output in a `result` block below.
- Press `C-RET` inside a paragraph to ask the model inline; the reply streams into a `> [!agent]` block that you can copy (`c`), adopt as your own prose (`e`), rerun (`r`), dismiss (`d`), or split into a chat (`s`).
- Narrow your focus with `C-x n n`, narrow both the view and the agent's context to one section with `C-x n N`, and widen back with `C-x n w`.
- Track document TODOs with `C-c C-t` and open the calendar agenda with `C-c A`.
- Add anchored margin notes to any text file with `C-c ! a` and review them with `M-x annotate-list`.
- Enter a distraction-free writing layout (document, scratch pad, and chat) with `M-x write`.
- Present a Markdown file as a slide deck with `C-c C-s`, or open PDFs with `M-x pdf-open`.

## Apps and uniform lists

In compos, an **app** is a listing with one row per item, a dedicated detail page buffer for each opened row, and the same actions on both. Because every list uses the same list mode, one set of keys works across buffers (`ibuffer`), directories (`dired`), chats (`chat-list`), todos (`todo`), mail, feeds, Sentry, Linear, and custom apps.

| Key | What it does in every list |
| --- | --- |
| `n`, `p` | Move down or up |
| `RET` | Open the item's detail page beside the list |
| `SPC` or `m` | Mark the row at point |
| `u` / `U` / `*` | Unmark row / unmark all / mark all |
| `x` | Run the list's action on all marked rows |
| `/` | Narrow rows live as you type |
| `f` / `\` | Add a filter / widen by one filter |
| `<` / `>` | Cycle grouping sections / sort order |
| `` C-` `` | Cycle through detail pages opened from this list |
| `g` | Refresh |
| `?` | Show all keys for this list |
| `q` | Quit |

Explore and extend your apps:

- Run `M-x app-registry` to see every built-in, installed, and personal app.
- Run `M-x packages` to browse, install, update, or unload packages from `compos-dev` or your own sources.
- Run `M-x browse` to read a web page as clean text inside a buffer (with automatic site parsers that strip menus and clutter).
- Install the compos Chrome extension (`~/.compos/chrome-extension`) so your agents can read pages behind your active browser logins.
- Want a new app for an external service? Ask your agent -- it writes the app in Scheme while compos runs.

## Shared todos and automation

You and your agents share one todo list stored in plain `todos.md` files.

- Press `C-x t` (`M-x todo`) to open the todo list for your current group.
- Press `c` to create a task, `t` to triage or approve a review item, `s` to start a task and spawn an agent chat on it, `d` to mark done, and `W` to park a task while waiting on someone.
- Press `C-c t` inside any chat to file that conversation as a todo.
- Every task keeps four parts: **Goal**, **Notes**, **Status** (`Done:` and `Left:`), and **Log**. The task is the durable record, so another chat or person can pick it up without reading the old transcript.

compos also runs background automation through its event bus:

- **Reactive listeners:** an agent can kick off a long build or wait for an incoming message, finish its turn immediately, and wake up automatically when the event arrives.
- **Cron jobs:** run `M-x cron-list` to view or trigger scheduled jobs.
- **Webhooks:** run `M-x webhooks` to receive HTTP events and trigger workflows.
- **Notifications:** run `M-x notifications` to review past notices and jump straight to the buffer they reference.

## Customizing and making compos yours

The easiest way to customize compos is to tell your chat agent what you want: "make my font bigger", "switch to a dark theme", "bind C-c d to dired", or "remember this layout".

You can also customize directly:

- `M-x customize`: search, change, and save any setting (saved to `~/.compos/custom.scm`).
- `M-x load-theme`, `M-x dark-theme`, `M-x light-theme`: preview and switch color themes.
- `C-h B` (`M-x keys`): browse and rebind keys interactively (`b` rebind, `u` revert).
- `M-:`: evaluate a single Scheme expression in the live editor.
- `~/.compos/init.scm`: your personal startup Scheme file. Saving a `.scm` file hot-reloads it without restarting.
- `M-x group-config`: edit a group's own `group.scm` (directory, layout, default model, and group keys).
- `compos.scm`: place a `compos.scm` at a Git project root to set project defaults (such as preferred model and effort).
- `C-c l` (`copy-buffer-link`): copy a link to the exact buffer and line to share with a teammate or paste into a chat.
- `M-x restart-daemon`: save your desktop and restart the daemon cleanly. All open buffers, windows, groups, and chat histories come back automatically.

## Getting help

| Key or command | What it shows |
| --- | --- |
| `C-h k` | Press any key to see what command it runs |
| `C-h m` | Describe the current buffer's mode and all its keys |
| `C-h b` | List every key active in the current buffer |
| `C-h h` | Search "How do I...?" task recipes with live keys |
| `C-h a` | Search commands, functions, modes, and settings by intent (`apropos`) |
| `C-h e` | Open `*Messages*` to inspect recent notices and errors |
| `C-h t` | Open or resume the interactive tutorial |
| `C-h ?` | List all help commands |
| `M-?` | Contextual help for the thing at point and current buffer |
| `M-x onboarding` | Start a guided one-step-at-a-time chat beside a practice window |

For per-mode keymaps and workflows across compos's main packages, see [docs/modes/README.md](docs/modes/README.md).

## Editor tips

Short, standalone tips suitable for showing periodically inside compos (echo area, welcome card, or tip popup).

### Navigation and windows

1. **Scroll the other window without moving.** Press `M-<down>` or `M-<up>` (or `C-M-v`) to read docs or a chat beside you while your cursor stays in your file.
2. **Undo a window layout mistake.** Press `C-c <left>` (`winner-previous`) to restore your previous window arrangement, and `C-c <right>` (`winner-next`) to go forward again.
3. **Close means hide, not delete.** Pressing `C-x 0` closes a window without losing the buffer; pressing `q` in help or a list pops back to whatever was under it.
4. **Switch window layouts in two keys.** Press `C-x l` followed by `1`, `2`, `=`, `c` (three columns), `r` (rows), or `+` (two panes plus a narrow chat).
5. **Jump between windows spatially.** Press `s-<left>` and `s-<right>` to move focus left or right, or `C-x o` to cycle through all windows.
6. **Cycle sibling buffers with one chord.** Press `` C-` `` (`group-next-mode-buffer`) to step through buffers of the same mode in your current group.
7. **Keep each task in its own group.** Press `C-x C-g n` (`s-g n`) to start a fresh group for a new task, and `C-x g` to jump back. Your windows and chats stay separated by task.
8. **Summon or hide popups.** Press `` M-` `` (`popper-cycle`) to toggle floating popup buffers such as help or messages without disturbing your layout.

### Editing and search

9. **Run commands in plain English.** Press `s-p` or `s-k` to open the command palette, type what you want to do, and press `RET` -- compos learns the phrase for next time.
10. **Cancel anything safely.** Halfway through a shortcut, search, or prompt? Press `C-g` to cancel without changing your text.
11. **Jump straight to any definition or heading.** Press `s-i` or `M-g i` (`imenu`) to jump to a function, class, or Markdown heading by name.
12. **Search your whole project with live previews.** Press `s-F` or `C-x p g` (`project-ripgrep`) to search ignored-free project files and preview matches as you move.
13. **Open files over SSH like local files.** In `C-x C-f`, type `/ssh:user@host:/path/to/file` to edit remote files with full mode and save support.
14. **Prefer Vim keys?** Run `M-x evil-mode` to switch to Vim motions and modal editing across text buffers while keeping special app keys intact.
15. **Resize one buffer or the whole app.** Use `C-+` and `C-_` to resize the current buffer's text, or `s-=` / `s--` / `s-0` to scale the entire UI.
16. **Zoom detail in or out.** Press `C-M-+`, `C-M--`, and `C-M-0` to expand or collapse detail levels in structured buffers.
17. **External edits merge cleanly.** When git or a formatter edits an open file on disk, compos merges those changes automatically and keeps your unsaved edits.

### Chats and agents

18. **Ask the agent without leaving your file.** Press `C-c RET` from any buffer to send a question to your group's chat while keeping your cursor where it is.
19. **Send exact lines to chat.** Select a passage and press `C-c r` to drop it into your group chat's input box, then type your question.
20. **Toggle between work and chat.** Press `C-c c` (or `C-c w`) to jump between your current file and the group's companion chat.
21. **Jump straight to an agent that needs you.** Press `C-c a a` (`agent-goto-attention`) to hop to the first chat waiting on a permission prompt or answer.
22. **Steer a running chat.** Press `C-RET` in a chat to send an instruction ahead of the queue, or press `C-g` to stop the current turn immediately.
23. **Configure everything for a chat in one menu.** Press `C-c b` (`llm-configure`) to switch connector, model, reasoning effort, MCP tools, and prompt sections.
24. **Test and benchmark your connectors.** Open `M-x llm-connectors` and press `t` on any connector (or `T` for all) to test a live reply and measure latency.
25. **Check what a chat cost.** Press `C-c $` (`chat-cost`) in any chat buffer to inspect token usage and cost.
26. **Start an independent background agent.** Press `C-c a n` (`agent-open`) to spin up a separate agent thread for a side task without cluttering your current chat.
27. **Run a skill from chat.** Type `/skill-name` at the start of a message, or run `M-x chat-show-skills` to see every skill available in your workspace.
28. **Control when an agent asks permission.** Press `C-c p` in a chat to cycle between `approve`, `auto`, and `ask`, and answer prompts with `C-c C-y` (once), `C-c C-a` (always), or `C-c C-n` (deny).
29. **Heal a stuck chat without losing history.** If a turn stalls after a crash or network drop, run `M-x chat-unstick` or `M-x chat-heal` instead of starting over.

### Writing, Markdown, and code

30. **Toggle Markdown preview and source.** Press `C-c C-v` in any `.md` file to switch between the rendered Morg page and raw source.
31. **Execute fenced code blocks in place.** Put your cursor inside a fenced code block in Markdown and press `C-c C-c` to run it and capture output in a `result` block below.
32. **Ask the AI inline inside a document.** Press `C-RET` in a Morg paragraph to stream a reply right below the paragraph as a quote you can adopt (`e`) or dismiss (`d`).
33. **Narrow both your view and the agent's context.** Press `C-x n N` on a heading to focus both the screen and the AI on that single section; press `C-x n w` to widen back.
34. **Walk code by syntax tree.** Run `M-x code-browse` to move through functions and blocks with `h`/`j`/`k`/`l` and fold nodes with `Tab`.
35. **See who wrote every revision.** Press `C-x v l` (`buffer-log`) to inspect a buffer's revision history and see whether you or an agent made each edit.
36. **Annotate any text file in the margin.** Press `C-c ! a` to attach a note that follows its text through edits, and review all notes with `M-x annotate-list`.

### Lists, apps, todos, and customization

37. **One set of keys works in every list.** Use `SPC` to mark rows, `/` to narrow, `<` and `>` to group or sort, and `x` to act on marked items across files, buffers, chats, todos, and apps.
38. **Turn a chat into a shared todo.** Press `C-c t` inside a chat to file it as a task, or press `C-x t` to open your group's shared todo list.
39. **Share a direct link to any buffer and line.** Press `C-c l` (`copy-buffer-link`) to copy a link that opens compos at that exact buffer and line.
40. **Ask the editor to customize itself.** You do not need to memorize settings or write boilerplate -- ask your chat agent to rebind a key, adjust a face, or build an app for your workflow.
41. **Never guess what a key does.** Press `C-h k` followed by any key to see its command, `C-h h` to search "How do I...?" recipes, and `C-h e` to read `*Messages*`.
42. **Read mail beside an AI agent.** Run `M-x mail` for a three-pane layout with your index, active thread, and companion chat, and press `L` to file a thread for your agent.
43. **Grab 2FA codes without switching apps (macOS).** With the bundled `imessage` package enabled, run `M-x otp` to copy the newest one-time verification code from Messages.
44. **Message your compos agents from your phone.** Connect an official `@BotFather` Telegram bot to route your phone messages straight into compos task groups.
45. **External messages never auto-send.** When an incoming email or WhatsApp event wakes a chat, compos marks it `untrusted?` so the agent stops and asks before sending, spending, or destroying.
