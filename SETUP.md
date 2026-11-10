# Set up compos from nothing

This file is for a person who does not have developer tools on their machine, and for the AI agent that does the work for them. [INSTALL.md](INSTALL.md) assumes the tools are there. This file gets them there, then hands over to INSTALL.md.

## For the person

You do not need to know what Elixir, Rust or Node are. Your agent installs them.

1. Get Claude Code. On macOS or Linux, open the Terminal app and paste:

   ```sh
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   Then type `claude` and sign in. Another coding agent (Codex, Gemini CLI) also works.

2. Say this to the agent:

   > Set up compos for me. Follow SETUP.md in <REPO-URL>, then INSTALL.md.

3. The agent asks before it installs anything on your machine, and it may ask for your login password. Say yes when you agree. It never needs your API keys; you type those yourself into `M-x setup` at the end.

## For the agent

Do the steps in order. Each step says how to check it. Stop and tell the person when a check fails. Explain each step in one plain sentence before you run it; the person is not a developer.

Rules:

- Ask the person before each system-wide install. Group the installs so you ask once per step, not once per package.
- When a command needs `sudo` or a password, tell the person to type it in the terminal. Never ask for it in the chat.
- Do not read, print, or store a secret value.
- Skip a step when its check already passes.

### 1. Find the platform

Run `uname -sm`. Find the Linux distribution in `/etc/os-release`. Tell the person what you found.

- macOS on Apple silicon (`Darwin arm64`): every step applies.
- macOS on Intel (`Darwin x86_64`): skip Python, laya does not run there.
- Linux: use the distribution's package manager for system packages, and mise for Erlang and Elixir.
- Windows: use WSL2 with Ubuntu, then follow the Linux steps inside it.

### 2. A package manager

- macOS: Homebrew. Check: `brew --version`. Install:

  ```sh
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

  The installer asks for the person's password and may install the Xcode Command Line Tools. Then add brew to the shell as the installer prints at the end, and open a new shell.
- Linux: the system one (`apt`, `dnf`, `pacman`). Install the build basics: `build-essential` (or `base-devel`), `curl`, `git`, `libssl-dev`, `libncurses-dev`, `autoconf`.

### 3. The tools

| Tool | macOS | Linux | Check |
|---|---|---|---|
| git | `brew install git` | package manager | `git --version` |
| Erlang/OTP and Elixir 1.19 or later | `brew install elixir` | mise, below | `elixir --version` |
| Rust | `brew install rustup && rustup-init -y` | `curl https://sh.rustup.rs -sSf \| sh -s -- -y` | `cargo --version` |
| Node and npm | `brew install node` | mise, below | `npm --version` |
| Google Chrome | `brew install --cask google-chrome` | the vendor package | the browser opens |
| Python 3.12 (Apple silicon only) | `brew install python@3.12` | not needed | `python3.12 --version` |

On Linux, distribution packages of Elixir are often too old. Use mise:

```sh
curl https://mise.run | sh
~/.local/bin/mise use -g erlang@latest elixir@latest node@lts
```

Erlang compiles from source here and takes several minutes. Run it in the background and tell the person it is slow on purpose. Add mise to the shell as its installer says, then open a new shell.

Check: every command in the Check column answers, in a new shell. If `elixir --version` shows a version below 1.19, the old one is first on the `PATH`; fix the `PATH` before you go on.

### 4. Hex and Rebar

```sh
mix local.hex --force
mix local.rebar --force
```

Check: `mix hex.info` answers.

### 5. Hand over to INSTALL.md

Tell the person the tools are in, then follow [INSTALL.md](INSTALL.md) from step 2. Its step 1 should now pass as it is.
