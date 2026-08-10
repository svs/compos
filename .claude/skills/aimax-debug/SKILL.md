---
name: aimax-debug
description: Drive a running ai-max daemon and read what it did — evaluate Scheme, dispatch keys, inspect frames/windows/buffers, and tail the browser bridge (both the daemon's side and the extension's forwarded errors). Use whenever debugging ai-max behaviour, the Chrome extension, or anything reported as "buggy" rather than reproducing by hand or asking the user to test.
---

# Debugging ai-max

`bin/aimax` talks to a running daemon over its RPC socket and reads its log.
Reach for it before guessing, and before asking the user to reproduce anything.

```sh
bin/aimax state                  # frames, windows, current buffer, prompt, browser
bin/aimax eval '(buffer-list)'   # any Scheme; the whole editor is reachable
bin/aimax keys C-x b             # dispatch keys as if typed, then show the prompt
bin/aimax bridge -n 60           # every browser op, both directions
bin/aimax log -f                 # the daemon log with LiveView noise stripped
bin/aimax tabs                   # what the browser last told us is open
```

`--home` (or `AIMAX_HOME`) picks the daemon; it defaults to `~/.aimax-web`.
The one on `~/.aimax` is usually the user's real editor — prefer a separate
daemon for experiments:

```sh
AIMAX_HOME=~/.aimax-web AIMAX_PORT=4005 AIMAX_NAME=web mix run --no-halt
```

## Reading the bridge

Every hop is one line, so a failure is readable rather than inferred:

```
browser <- chord %{"keys" => ["C-x","b"], "tab" => 42} frame=f-oboszna   request in
browser => tabs %{}                                                      we asked the browser
browser <= ok %{"tabs" => [...]}                                         it answered
browser -> chord ok %{"message" => "ran switch-to-buffer", ...}          our reply
browser-ext: ...                                                         the EXTENSION's own error
```

`browser-ext` lines are the service worker's console forwarded over the same
socket. Its devtools window is never open, so without this an error in the
extension is invisible from here.

## Driving both ends

For anything spanning the browser, stand in for the extension: open a
WebSocket to `ws://127.0.0.1:<port>/browser`, answer the ops the daemon sends
(`tabs`, `activate`, …), and drive the editor over the RPC socket at the same
time. That reproduces a full flow — keypress in a page, prompt, RET, result —
with no human and no Chrome. There is a worked example in the session
scratchpad (`drive.py`); the shape is:

1. connect, read the `hello`
2. answer whatever the daemon asks on connect (it primes its tab cache)
3. send `{id, op: "chord", keys: [...], tab, frame, window}`
4. poll `{op: "mb-state"}` for the prompt, `{op: "mb-key", spec}` to answer it
5. assert with `bin/aimax eval` on the editor's actual state

## What the extension can and can't tell you

- **Can**: its errors and warnings (forwarded), which daemons it is connected
  to, which tab is registered as each window's ai-max frame.
- **Can't**: content-script state in an arbitrary page, without either
  `chrome://extensions` devtools (a human has to open it) or adding a
  diagnostic op. `chrome://` pages are closed to automation.
- **Watch for**: a stale content script. Reloading the extension orphans the
  script in every already-open page; it tears itself down now, but the page
  still needs a refresh to get the new one.

## Traps that have already cost time

- **`(current-buffer)` answers with the minibuffer** while a prompt is open.
  For "the buffer I'm looking at", ask the selected window — `(chrome--here)`.
- **A prompt left open persists in `desktop.etf`** and survives a restart.
  `bin/aimax eval '(when (minibuffer-state) (minibuffer-cancel!))'`.
- **`minibuffer-state` returns a visible WINDOW of candidates**, not all of
  them. Check `'total` before concluding something is missing from a list.
- **`dispatch-keys` runs off-process** (calling KeyDispatch from inside Session
  deadlocks), so a prompt may open *after* the reply. Poll, don't assume.
- **This Scheme has no rest arguments and no `list?`.** `(define (f a . rest))`
  silently makes a 3-parameter function.
