# ai-max desktop shell

A thin [Tauri](https://tauri.app) client over the editor daemon. The daemon
owns all state and serves any client (this shell, browser tabs, the RPC
socket); the shell just ensures a daemon is running and opens a webview on
`http://127.0.0.1:4004`. Closing the window leaves the daemon — and your
buffers — running.

## Run

```sh
cd desktop/src-tauri
cargo run
```

- `AIMAX_URL` — daemon to connect to (default `http://127.0.0.1:4004`).
  A daemon is auto-spawned only for loopback hosts; point this at a remote
  ai-max and the shell is a pure client.
- `AIMAX_DIR` — checkout to start the daemon from (default: this repo,
  resolved at compile time).

## Not yet done

- Bundling (`bundle.active` is off; needs icons + signing config, and a
  Burrito-packaged release so end users don't need Elixir installed).
- Native menu entries for editor commands (M-x over the RPC socket).
- The webview is a plain client: keybindings, rendering and reload-on-boot-id
  behavior are identical to a browser tab.
