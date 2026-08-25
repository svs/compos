# ai-max browser extension

ai-max's keys and commands in every tab, and a wire so the editor can drive any
of them.

- <kbd>M-x</kbd> in any page completes over the editor's real command table.
  <kbd>Cmd-P</kbd> opens intent search over command docs and task recipes. The
  chosen action runs in the daemon — a page is an input device, the editor
  still does the work.
- <kbd>C-x</kbd> starts a chord; the whole sequence goes through the same key
  dispatcher the GUI uses.
- From Scheme, any tab is addressable: run JS in it, read it, put a line on its
  screen, type into it for real.

## Install

1. `chrome://extensions`
2. Turn on **Developer mode** (top right)
3. **Load unpacked** → pick this directory

## Getting there

Type **`aimax`** in the address bar, then space or Tab. It lists the daemons
that are actually running, by name, and Enter takes you to one — focusing an
existing ai-max tab rather than opening a second (a second tab on the same
daemon is a second frame, which is rarely what you meant).

**Alt+Shift+A** jumps to this window's ai-max directly. Rebind it at
`chrome://extensions/shortcuts`.

## One window, one ai-max

Each ai-max page tells the extension which frame it is, and the extension tells
the daemon which browser window that frame sits in. The binding decides where
things happen:

- `C-x b` in a page offers the tabs of **that** window, beside the buffers.
- A tab the editor opens lands in the frame's own window. A chat on the left
  screen answers there, not in whichever window Chrome focused last.
- **Alt+Shift+A** and a confirmed prompt raise that window's ai-max tab.

Drag the ai-max tab to another window and the binding follows it.

No `/etc/hosts` entry and no port-80 listener: a hosts file maps a name to an
address, not a port, and Chrome treats a bare word as a search anyway.

## Configure

The extension serves **every daemon you run**. By default it connects to port
4004 and scans 4004–4013, so a daemon you just started is picked up with no
configuration. The **Options** page pins ports, changes the range, shows what's
connected, and turns key capture off if <kbd>C-x</kbd> is fighting a site.

Run a second daemon like this:

```sh
AIMAX_HOME=~/.aimax-work AIMAX_PORT=4005 AIMAX_NAME=work mix run --no-halt
```

`AIMAX_HOME` is enough on its own: the RPC socket and desktop file follow it, so
two daemons never fight over `~/.aimax/sock`. See `config/runtime.exs`.

Unlike the earlier browse-in-a-buffer version, a daemon may address **any** tab,
not only ones it opened — that's the point of an ambient layer.

## Gemini Nano

The `gemini-nano` connector runs Chrome's built-in Prompt API in the active tab.
Use a Chrome build with `LanguageModel` enabled, load this extension, then set
the connector for new chats in `~/.aimax/init.scm`:

```scheme
(set! *default-connector* "gemini-nano")
```

Gemini Nano runs locally in Chrome. It needs no API key. The connector is
stateless, so each request sends the saved chat transcript to Chrome again.

## From Scheme

```scheme
(tab-list (lambda (tabs) (message (number->string (length tabs)))))
(tab-say 42 "the editor is talking to your tab")
(tab-eval 42 "document.title" (lambda (v) (message v)))
(tab-read 42 (lambda (r) (buffer-append! "*scratch*" (chrome--get r 'text))))
(tab-type 42 "typed for real")          ; trusted input, via CDP
(tab-click 42 120 340)
(tab-open "https://example.com/")       ; in this frame's browser window
(tab-open "https://example.com/" 3)     ; or in window 3
```

`M-x list-tabs` and `M-x switch-to-tab` are built on the same verbs.

## How it talks to pages

Two mechanisms, deliberately:

- **Content scripts** carry the overlay, the key capture, and ordinary reads.
  They run in an isolated world that page JavaScript cannot see or enumerate,
  and they need no `debugger` permission — so no infobar.
- **CDP** (`chrome.debugger`) comes out only for input that has to be trusted.
  `el.click()` and `dispatchEvent` carry `isTrusted: false`, which a hardened
  page can check; `Input.dispatchKeyEvent` does not. The extension attaches on
  demand and **detaches after 30s idle**, so the "started debugging this
  browser" bar isn't permanent — it appears while ai-max is typing and goes
  away again.

## Limits

- **Top frame only.** The overlay and reads don't reach into cross-origin
  iframes yet.
- **`C-x` is capture-everything.** On macOS that's free (cut is ⌘X), but on
  Linux/Windows it collides with cut. Turn key capture off in Options if it
  bites.
- **`chrome://` pages and the Web Store** run no content scripts, so no overlay
  and no `read` there. CDP ops still work.
- **The palette targets one daemon.** With several connected, a tab talks to
  whichever answers first.
