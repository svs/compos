# Install Compos on Linux

Use Linux x86_64 with glibc 2.39 or later.
Bash, curl, tar, and GNU coreutils are required.

## Install with one command

Run this command in a Bash or Zsh terminal:

```bash
COMPOS_REPO=harsh098/compos bash -c 'installer=$(curl -fsSL https://raw.githubusercontent.com/harsh098/compos/main/bin/install-linux.sh) && bash -c "$installer"'
```

The command installs Compos in `$HOME/.local/bin/compos`.
Administrator access is not required for this directory.
The installer downloads the release and does two SHA-256 checksum checks before installation.

The terminal shows `Installed Compos at` when installation is complete.
The installer also shows the release URL and the start command.

**Release source:** This command selects `harsh098/compos` through `COMPOS_REPO`.
The script uses `svs/compos` when this variable is not set.
Upstream has no Linux release at this time.

## Add Compos to PATH

Run this command in the terminal where you will start Compos:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

This setting applies to the current terminal.
The installer also prints the PATH command for the selected installation directory.

To keep this setting for future terminals, add the same line to your shell startup file:

| Shell | Startup file |
| --- | --- |
| Bash | `$HOME/.bashrc` |
| Zsh | `${ZDOTDIR:-$HOME}/.zshrc` |

Then open a new terminal.
Run `command -v compos` to show the executable path.

## Start Compos

1. Run this command:

   ```bash
   COMPOS_BIND=127.0.0.1 COMPOS_PORT=4004 compos
   ```

2. Wait for `http://localhost:4004` to appear in the terminal.
3. Open <http://localhost:4004> in a browser.

Keep the terminal open while you use Compos.
The first start extracts the runtime into the user data directory.

To stop Compos, press `Ctrl+C` in the server terminal.
To start Compos again, run the same start command.

## Select the release source

`COMPOS_REPO` selects the GitHub repository that supplies the release.
The default is `svs/compos`.
The installer does not select another repository automatically.

The installation command above uses `harsh098/compos` because that repository has a Linux release.

If upstream has a Linux release, run this command to use the default:

```bash
bash -c 'installer=$(curl -fsSL https://raw.githubusercontent.com/harsh098/compos/main/bin/install-linux.sh) && bash -c "$installer"'
```

If `COMPOS_REPO` is already set, run `unset COMPOS_REPO` first.

To use another mirror, replace `harsh098/compos` in the environment variable with that mirror's repository name.

The selected repository must have a published release marked Latest.
That release must contain these two files:

- `compos-linux-x86_64.tar.gz`
- `compos-linux-x86_64.tar.gz.sha256`

The installer downloads both files from the same release.
It installs the executable only after both checksum checks pass.

## Select the installation directory

`COMPOS_BIN_DIR` selects the directory for the executable.
The default is `$HOME/.local/bin`.

To install Compos in `$HOME/apps/compos/bin`, run this command:

```bash
COMPOS_BIN_DIR="$HOME/apps/compos/bin" COMPOS_REPO=harsh098/compos bash -c 'installer=$(curl -fsSL https://raw.githubusercontent.com/harsh098/compos/main/bin/install-linux.sh) && bash -c "$installer"'
```

Run the PATH command that the installer shows for the selected directory.
Then use `compos` to start the installed executable.

## Requirements

The Linux release is built on Ubuntu 24.04.
Use glibc 2.39 or later.
This installer supports Linux x86_64 only.

The executable contains the application and its runtime.
A C compiler, Elixir, Erlang, Rust, Zig, and the GitHub CLI are not required for installation.

If a required command is missing, install the system packages.

For Ubuntu 24.04 or later, run this command:

```bash
sudo apt-get update && sudo apt-get install -y bash curl tar coreutils libc-bin libtinfo6 libstdc++6
```

For Fedora, run this command:

```bash
sudo dnf install -y bash curl tar coreutils glibc ncurses-libs libstdc++
```

Then run the installation command again.

## Installed files

| Item | Default location |
| --- | --- |
| Executable | `$HOME/.local/bin/compos` |
| Settings and saved data | `$HOME/.compos` |
| Extracted runtime | `$HOME/.local/share/.burrito` |

The runtime location can change when `XDG_DATA_HOME` is set.
Set `COMPOS_HOME` to use another directory for settings and saved data.

## Install an update

1. Stop Compos.
2. Run the installation command again.
3. Start Compos.

The installer replaces the executable after the checksum checks pass.
Your settings and saved data remain in place.

## Remove Compos

1. Stop Compos.
2. Run this command:

   ```bash
   rm -f "$HOME/.local/bin/compos"
   ```

If you selected another installation directory, remove `compos` from that directory.
Your settings and saved data remain in place.

## Correct installation problems

| Terminal message | Action |
| --- | --- |
| `No published release exists` | Set `COMPOS_REPO` to a repository with a Linux release. |
| `Linux asset ... is unavailable` | Make sure that the release contains both files listed above. |
| `Checksum verification failed` | Run the installation command again. |
| `Use glibc 2.39 or later` | Use a supported Linux system. |
| `compos: command not found` | Run the PATH command shown above. |

If a checksum failure occurs again, report the release URL and terminal message.

If port 4004 is in use, start Compos with different ports:

```bash
COMPOS_BIND=127.0.0.1 COMPOS_PORT=4014 COMPOS_APP_PORT=4015 compos
```

Then open <http://localhost:4014>.
