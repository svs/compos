<img src="site/images/compos-logo-clear.png" alt="compos" width="160">

# compos

## What you get

- **Your context comes to you.** Files, mail, issues, feeds, and chats are all buffers. The same commands and the same agents work on all of them.
- **An AI chat beside every buffer.** Open a chat for a buffer or for a group of buffers. Use Claude Code, Codex, or an API key that you already have.
- **Fast agents.** Compos agents writes small programs that changes your buffers. They don't make many tool calls, preferring to load context and then operate on it in code-mode.

## Requirements

- **An AI agent.** Claude Code or Codex is preferred.
- **Google Chrome**, with the compos Chrome extension.
- **For coding:** add JEV and an embedding model. An embedding model needs an OpenRouter or OpenAI key, which you set in `M-x setup`.

## Install

Ask your AI agent to follow [SETUP.md](SETUP.md):

1. Install Claude Code, or another coding agent.
2. Tell it: "Set up compos for me. Follow SETUP.md in https://github.com/svs/compos"
3. The agent gets the compos binary, starts it, and connects to the editor.
4. The agent asks before it changes your computer. You type your API keys into `M-x setup`.
5. Compos opens in Chrome. Install the Chrome extension when the agent tells you to.

To build from source, point your agent at [INSTALL.md](INSTALL.md). To work on compos, read [DEVELOPMENT.md](DEVELOPMENT.md).


## Why Compos?

### on the plight of the modern worker, and some solutions

The modern knowledge worker - programmer, lawyer, teacher and so on - suffering terribly. Little by little the complexity in their life has increased to the point where the original conception of knowledge worker interfaces have long since ceased to be useful. The dominant computing paradigm of floating windows disconnected from each other visually and contextually is woefully out of date. 

We can tell it is woefully out of date because computer use remains a hard problem. The agents cannot manipulate your computer easily. Now this might be secure by design and what not, any number of reasons, but you can't deny that it sure makes it hard to get stuff done.

Multiple browser windows and profiles with dozens of tabs each, none of them accessible directly and each with their own context locked away behind a browser dom and hidden amongst a litany of tailwind classes and also a hundred-odd nextjs imports. Neither human nor agent can work here.

### a proposal for a new UX

well forgive me if I overstate the case here. It's not a new UX. It's one of the earliest UXs in computers, built back when only power users could even get access to a computer. And it is time for it to make a comeback.

The core philosophy is simple - you do not go to your context, your context comes to you. now whether that's your email, your issue tracker, your rss feed - all of it is brought into the environment into a uniform access pattern with all your tools available for it.

Then you can compose your context perfectly for any task you might have. Any agent can work on any buffer or multiple buffers connecting the various text in your life - from error traces to sales decks.



### Emacs rebuilt on the BEAM.

Compos is a headless editor daemon in Elixir, scripted in Scheme, rendered by the browser. You can think of it as a modernised emacs - more computation environment than text editor. AIs then write small scheme programs to manipulate the buffer states to give you the desired output. This eliminates the need for a lot of wasteful mcp tool calls and slow LLM mediated roundtrips in favour of direct access to all your data as structured data. You build your perfect work environment by talking to it.


## Documentation

- [SETUP.md](SETUP.md): install the binary.
- [INSTALL.md](INSTALL.md): build from source.
- [DEVELOPMENT.md](DEVELOPMENT.md): run from source, the repository layout, the design, and how to extend compos.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): the architecture. Read it first. `docs/` also holds the roadmap and the component contract.

## License

See [`LICENSE`](LICENSE).
