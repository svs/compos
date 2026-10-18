//! compos desktop shell: a thin Tauri client over the editor daemon.
//!
//! The daemon owns all state (buffers, windows, desktop.etf) and serves any
//! client — this shell, browser tabs, the RPC socket — so the shell's whole
//! job is: make sure a daemon is running, then show a webview on it.
//! Closing the shell leaves the daemon (and your buffers) running.
//!
//! COMPOS_URL points the shell at a daemon (default http://127.0.0.1:4004);
//! a daemon is auto-spawned only for loopback hosts. COMPOS_DIR overrides
//! the checkout the daemon is started from. COMPOS_SPAWN replaces the
//! command that starts the daemon, so the shell can start a release build
//! instead of the dev loop:
//!
//!   COMPOS_URL=http://localhost:4014 \
//!   COMPOS_SPAWN='COMPOS_HOME=~/.compos-rel COMPOS_PORT=4014 \
//!     _build/prod/rel/compos/bin/compos daemon' cargo run
//!
//! COMPOS_HOME names the directory the shell writes daemon.log in.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::net::{TcpStream, ToSocketAddrs};
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use tauri::menu::{Menu, MenuItem, Submenu};
use tauri::Manager;
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};

/// A hard reload: fetch the document and every script and stylesheet
/// with `cache: "reload"`, so the cache holds fresh copies, then reload.
/// The cookies stay, so the daemon sees the same client.
const HARD_RELOAD_JS: &str = r#"
(async () => {
  const urls = [location.href];
  document.querySelectorAll("script[src], link[rel=stylesheet][href]").forEach((el) => {
    const u = el.src || el.href;
    if (u && u.startsWith(location.origin)) urls.push(u);
  });
  await Promise.allSettled(urls.map((u) => fetch(u, { cache: "reload" })));
  location.reload();
})();
"#;

fn daemon_url() -> String {
    // localhost, not 127.0.0.1: origin-checked sockets (the PTY channel)
    // compare the Origin header against the configured host, and the two
    // loopback spellings do not match each other.
    std::env::var("COMPOS_URL").unwrap_or_else(|_| "http://localhost:4004".to_string())
}

/// (host, port) out of an http URL — enough parsing for a health check.
fn host_port(url: &str) -> (String, u16) {
    let rest = url.split("://").nth(1).unwrap_or(url);
    let authority = rest.split('/').next().unwrap_or(rest);
    match authority.split_once(':') {
        Some((h, p)) => (h.to_string(), p.parse().unwrap_or(80)),
        None => (authority.to_string(), 80),
    }
}

fn daemon_up(host: &str, port: u16) -> bool {
    // try EVERY resolved address: localhost resolves to ::1 first on
    // macOS, and the daemon listens on 127.0.0.1 — probing only the
    // first address reported a running daemon as down (and spawned a
    // doomed second one)
    (host, port)
        .to_socket_addrs()
        .map(|mut addrs| {
            addrs.any(|addr| TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok())
        })
        .unwrap_or(false)
}

/// The umbrella checkout. COMPOS_DIR wins; the compile-time fallback (two
/// levels up from this crate) covers dev builds from the repo.
fn project_root() -> PathBuf {
    match std::env::var("COMPOS_DIR") {
        Ok(dir) => PathBuf::from(dir),
        Err(_) => PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."),
    }
}

/// The command that starts a daemon. COMPOS_SPAWN wins; the default is the
/// dev loop, which runs in the foreground and so takes `exec`.
fn spawn_command() -> String {
    std::env::var("COMPOS_SPAWN").unwrap_or_else(|_| "exec mix run --no-halt".to_string())
}

/// The directory the daemon log goes in — the same home the daemon uses.
fn home_dir() -> String {
    std::env::var("COMPOS_HOME").unwrap_or_else(|_| "~/.compos".to_string())
}

fn spawn_daemon() {
    let root = project_root();
    let home = home_dir();
    // same launch shape as the dev loop: log to $COMPOS_HOME/daemon.log, detach
    let script = format!(
        "mkdir -p {home} && {cmd} >> {home}/daemon.log 2>&1",
        home = home,
        cmd = spawn_command()
    );
    let spawned = Command::new("sh")
        .arg("-c")
        .arg(&script)
        .current_dir(&root)
        .spawn();

    if let Err(e) = spawned {
        eprintln!("compos-shell: could not start daemon in {}: {e}", root.display());
    }
}

fn main() {
    let url = daemon_url();
    let (host, port) = host_port(&url);
    let loopback = matches!(host.as_str(), "127.0.0.1" | "localhost" | "[::1]");

    if loopback && !daemon_up(&host, port) {
        spawn_daemon();
    }

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        // closing the window asks first: a stray Cmd-W must not drop the
        // shell. The daemon keeps running either way.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let w = window.clone();
                window
                    .dialog()
                    .message("The daemon and your buffers keep running.")
                    .title("Close the compos window?")
                    .parent(window)
                    .buttons(MessageDialogButtons::OkCancelCustom(
                        "Close".to_string(),
                        "Cancel".to_string(),
                    ))
                    .show(move |close| {
                        if close {
                            let _ = w.destroy();
                        }
                    });
            }
        })
        .setup(move |app| {
            // the default menu, plus a Shell menu with the two browser
            // reloads: Cmd-R re-reads the page, Cmd-Shift-R first fetches
            // the page and its scripts and styles past the cache. The
            // editor claims no Cmd-R chord, so the accelerator reaches the
            // menu.
            let menu = Menu::default(app.handle())?;
            let reload = MenuItem::with_id(app, "reload", "Reload", true, Some("CmdOrCtrl+R"))?;
            let hard_reload = MenuItem::with_id(
                app,
                "hard-reload",
                "Hard Reload",
                true,
                Some("CmdOrCtrl+Shift+R"),
            )?;
            let shell_menu = Submenu::with_items(app, "Shell", true, &[&reload, &hard_reload])?;
            menu.append(&shell_menu)?;
            app.set_menu(menu)?;
            app.on_menu_event(|handle, event| {
                let Some(w) = handle.get_webview_window("main") else { return };
                match event.id().as_ref() {
                    "reload" => {
                        let _ = w.eval("location.reload()");
                    }
                    "hard-reload" => {
                        let _ = w.eval(HARD_RELOAD_JS);
                    }
                    _ => {}
                }
            });

            let handle = app.handle().clone();

            // wait for the daemon, then send the splash window to it
            std::thread::spawn(move || {
                let deadline = Instant::now() + Duration::from_secs(60);

                while Instant::now() < deadline {
                    if daemon_up(&host, port) {
                        // give the splash a beat to exist before navigating
                        std::thread::sleep(Duration::from_millis(200));
                        if let Some(w) = handle.get_webview_window("main") {
                            let _ = w.eval(&format!("location.replace({url:?})"));
                        }
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(300));
                }

                if let Some(w) = handle.get_webview_window("main") {
                    let _ = w.eval(
                        "var s = document.getElementById('status'); \
                         if (s) { s.textContent = 'daemon did not come up — check ~/.compos/daemon.log'; \
                                  s.classList.remove('dot'); }",
                    );
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running compos shell");
}
