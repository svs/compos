# Start with AI in Compos

Compos lets you chat with a model and ask an agent to help with your work.
This guide starts with a working connection, then shows how to use a chat
alongside a file and when to start a separate agent thread. You can explore
the editor before setting up AI.

You'll see commands written like `M-x setup-inference`. To run one, hold
Option (or Alt) and press `x`, type the command name, then press Return.

## Four words

- A **large language model**, or **LLM**, takes text and returns a response.
  The model alone does not edit a file or run a command.
- A **chat** is a Compos buffer that holds your conversation. It belongs to a
  group, like your other work buffers.
- An **agent** uses a model and tools to do work. It may read buffers, propose
  edits, or ask for permission before an action.
- A **connector** is how Compos reaches a model or an external agent. The
  connector, model, and permissions are separate choices.

A chat can use a direct API model or an external agent connector. Start with a
chat. You do not need to spawn a separate agent thread for your first question.

## 1. Choose a connection

Type `M-x setup-inference` to see what Compos detects on this machine. The
scan checks connector declarations, local commands, and registered keys. It
does not test an account login, browser support, or a reply. The command opens
a report and asks you to choose a default connector. In the list, hold Control
and press `n` or `p` to move the highlight, then press Return to choose. Press
`C-g` to close the question without choosing. Test a reply in step 3.

| Connector | What you need |
| --- | --- |
| `codex-app-server` | The `codex` command and a Codex login. It uses the Codex app-server, not an OpenAI API key. |
| `claude-code` | The `claude-agent-acp` adapter and a working Claude Code login. |
| `opencode` | The `opencode` command and a model provider configured in OpenCode. |
| `deepseek` | The `dsh` command and a configured DeepSeek Harness ACP profile. |
| `api` | A registered key for the provider of the model you choose. Direct API requests may cost money. |
| `gemini-nano` | A browser with a working Chrome Prompt API. It needs no API key, but it is not available in every browser. |

For Codex, sign in with `codex login` in a terminal before the first Compos
chat. For Claude Code, run `claude auth status` and check the account. If it
is not signed in, run `claude auth login`. Then install the adapter with
`bun add -g @agentclientprotocol/claude-agent-acp`.
For other external agents, install the named program and complete its provider
login or key setup. The scan can see a program when its account is not ready.

For a direct OpenRouter API model, type `M-x setup-bot`. Follow its OpenRouter
question to enter a key. You may skip its unrelated service questions.
`M-x setup-secrets` helps choose secret storage; it does not, by itself,
register a model key. Do not paste a key into a chat or this guide.

Other direct API providers need a registered key. The setup scan recognizes
Anthropic, OpenAI, OpenRouter, Google, DeepSeek, Groq, and xAI keys. For
example, if `OPENAI_API_KEY` is available to Compos, put this line in
`~/.compos/ai-config.scm` and reload that file:

```scheme
(register-llm-key! "openai" (key-get "OPENAI_API_KEY"))
```

Choose an OpenAI model under the `api` connector. A key for one provider does
not make another provider's models work.

## 2. Configure a chat

`M-x setup-inference` can save a default connector for new chats; it does not
choose a model. In a chat, `C-c b` lets you choose its model, or leave it on
`default` to let the connector choose. Choosing a connector does not sign you
in.

>> Type `C-c n` to make a new chat in this group.
   Type `C-c b` in the chat. The left column lists presets; the right column
   shows the setup. Press the right arrow to move to the setup. Press `b` to
   choose a connector. Press `m` to choose a model, or select `default` to let
   the connector choose. Press `ESC` to apply the setup and close the menu.

If a newer model is missing, first choose its connector and leave the model
on `default`. Press `ESC` to connect, then open `C-c b` and `m` again. For
example, Codex reports GPT-6 Luna after it connects, even if the first list
only shows older models.

In this menu, `C-g` also applies the selected setup and closes the menu. It
does not undo changes made in the menu.

## 3. Check a real reply

>> Say hello to your agent: type `Hi!` and press `RET`.
   If your agent replies, the connection works.

If Compos shows an authorization or model error, setup is not complete. A
model name in the picker and a positive scan are not enough.

- **Command not found:** Install the connector's program and run
  `M-x setup-inference` again.
- **Unauthorized:** Sign in to that connector, then try a new chat. Compos
  gives Codex its own home and copies your Codex login there once. If Codex
  still returns 401 after a normal login, sign in to that home from a terminal:
  `CODEX_HOME="$HOME/.compos/codex-home" codex login`.
- **API key or model error:** Check that the key is registered for the same
  provider as the model. Choose another model with `C-c m` in the chat.
- **Gemini Nano does not reply:** Check browser Prompt API support or choose
  another connector. The connector being listed does not prove browser support.

## 4. Keep a conversation with your work

The chat remembers its earlier turns. You can ask a follow-up without starting
over. A group keeps that chat beside the files and other buffers for one task.

>> In the chat that answered you, ask one follow-up question and press `RET`.
   Open a work buffer with `C-x C-f` and choose a file you want to read.
   Type `C-c c` to open this buffer's group chat. Type `C-c w` to move between
   the chat and the work buffer.

If the file belongs to a different group, `C-c c` opens that group's chat,
not the first chat you made. Type `M-x chat-list` to find an earlier chat by
its name or by a word in the conversation. Type `C-c n` when you want a new
conversation in the current group; the old one stays available.

## 5. Ask about a file

With tools enabled, an agent can inspect a buffer in its group. A model-only
chat may not have that access. Start with a question that does not ask it to
change anything.

>> While looking at a file, type `C-c RET` and ask "What is this file about?"
   Press `RET`. You stay in the file; the answer goes to its group chat.
   If the agent cannot read the file, give it the relevant text explicitly
   with the next exercise.

To send just part of a file, put point at the start of a line and type
`C-SPC` to set the mark. Move to the end of the line with `C-e`. On macOS, if
`C-SPC` switches input sources, use `M-SPC` instead.

>> With that text selected, type `C-c r`. Compos opens the chat and adds the
   selection to its input. Type "Explain this line" after it, then press
   `RET`. `C-c r` adds context; it does not send the question for you.

The first exercise asks the agent to find context; the second supplies exact
text. Use the second when you want an answer about a particular passage or
when the chosen connector has no buffer-reading tools. Do not include secrets
in text you send to a hosted model.

## 6. Give an agent a separate task

A group chat is for questions alongside your current work. `C-c a n` starts
a new agent thread for a task that can have its own conversation. It uses the
default connector from step 1, not necessarily the connector you chose for a
particular chat. Set up a working default before trying it.

>> Type `C-c a n`. At the task prompt, enter "Suggest a three-step plan for
   organizing my project notes. Do not edit files" and press `RET`. The new
   thread opens in another window. Type `C-x o` to move between windows.

The task starts as soon as you submit it. If you only want another
conversation, use `C-c n` instead. If you want to find the thread later, use
`M-x chat-list`.

## 7. Choose what the agent may do

Answers and actions are different. An agent may read a buffer, edit one, run
a command, or use its own file tools. Check what it proposes before
you allow an action. Do not assume that changing the model changes these
permissions.

In a chat, `C-c b` shows its connector, model, effort, and tools. Press `+`
there for the extra fields: `k` chooses when this chat asks before acting,
and `f` chooses what the agent's own file tools may do. The file-tools choice
applies to every chat, not just this one. If a permission prompt appears,
`C-c C-y` allows it once and `C-c C-n` denies it. `C-c C-a` allows that tool
without asking again in this chat; use it only when you mean to make a
standing rule.

For an ordinary question, you do not need to change the permission settings.
If you ask for an edit, inspect the result in the buffer before saving it.

## Keys to keep

| Key | When to use it |
| --- | --- |
| `M-x` | Find a command by name, such as `setup-inference` or `setup-bot`. |
| `C-c n` | Start a new chat buffer in the current group. |
| `C-c c` | Open the current group's chat without starting a new one. |
| `M-x chat-list` | Find an existing chat or agent thread. |
| `C-c b` | Choose a chat's connector, model, tools, and permissions. |
| `C-c m` | Change the model of the current chat. |
| `RET` | Send the text in a chat's input. |
| `C-g` | Stop a reply in a chat. In `C-c b`, it applies and closes instead. |
| `C-c w` | Switch between a work buffer and its group chat. |
| `C-c RET` | Ask the group chat while you stay in a work buffer. |
| `C-c r` | Add selected text to the group chat's input. |
| `C-c a n` | Prompt for a task and spawn a separate agent thread. Use this after your first chat works. |
| `C-h k` | Find out what a key does in the current buffer. |
| `C-h h` | Find a recipe for a task, including AI setup. |
| `C-h ?` | See the available help commands. |

The main tutorial explains buffers, groups, windows, and more commands. Type
`C-h t` to open or resume it. Type `C-h h` when you want a task recipe.

[Back to Welcome](compos:setup/welcome)
