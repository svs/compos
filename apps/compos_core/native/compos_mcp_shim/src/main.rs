//! compos-mcp-shim: one agent's stdio MCP, copied to the daemon's MCP socket.
//!
//! An ACP adapter starts each MCP server as a stdio subprocess. This one
//! does no MCP work. It sends the agent's slug (COMPOS_AGENT) as the first
//! line, then copies stdin to the socket and the socket to stdout. The
//! daemon (Compos.Rpc.McpServer) serves the tools. On stdin EOF the shim
//! closes its write side; the daemon answers the calls in flight and
//! closes, and the shim exits.

use std::env;
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::process;
use std::thread;

fn main() {
    let path = env::var("COMPOS_MCP_SOCK").unwrap_or_else(|_| {
        format!("{}/.compos/sock-mcp", env::var("HOME").unwrap_or_default())
    });

    let mut sock = UnixStream::connect(&path).unwrap_or_else(|e| {
        eprintln!("compos-mcp-shim: cannot connect to {path}: {e}");
        process::exit(1)
    });

    let slug: String = env::var("COMPOS_AGENT")
        .unwrap_or_default()
        .chars()
        .filter(|c| *c != '\n' && *c != '\r')
        .collect();

    if sock.write_all(format!("{slug}\n").as_bytes()).is_err() {
        process::exit(1);
    }

    let mut to_daemon = sock.try_clone().unwrap_or_else(|_| process::exit(1));
    thread::spawn(move || {
        let _ = io::copy(&mut io::stdin().lock(), &mut to_daemon);
        let _ = to_daemon.shutdown(Shutdown::Write);
    });

    // flush each chunk: the agent waits for every reply frame
    let mut out = io::stdout().lock();
    let mut buf = [0u8; 65536];
    loop {
        match sock.read(&mut buf) {
            Ok(0) | Err(_) => process::exit(0),
            Ok(n) => {
                if out.write_all(&buf[..n]).and_then(|_| out.flush()).is_err() {
                    process::exit(0);
                }
            }
        }
    }
}
