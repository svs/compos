//! compos desktop shell: a thin Tauri client over the editor daemon.
//!
//! The daemon owns all state (buffers, windows, desktop.etf) and serves any
//! client — this shell, browser tabs, the RPC socket — so the shell's whole
//! job is: make sure a daemon is running, then show a webview on it.
//! Closing the shell leaves the daemon (and your buffers) running.
//!
//! COMPOS_URL points the shell at a daemon (default http://127.0.0.1:4004);
//! a daemon is auto-spawned only for loopback hosts. COMPOS_DIR overrides
//! the checkout the daemon is started from.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::net::{TcpStream, ToSocketAddrs};
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use tauri::Manager;

fn daemon_url() -> String {
    std::env::var("COMPOS_URL").unwrap_or_else(|_| "http://127.0.0.1:4004".to_string())
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
    (host, port)
        .to_socket_addrs()
        .ok()
        .and_then(|mut addrs| addrs.next())
        .map(|addr| TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok())
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

fn spawn_daemon() {
    let root = project_root();
    // same launch shape as the dev loop: log to ~/.compos/daemon.log, detach
    let spawned = Command::new("sh")
        .arg("-c")
        .arg("mkdir -p ~/.compos && exec mix run --no-halt >> ~/.compos/daemon.log 2>&1")
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
        .setup(move |app| {
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
