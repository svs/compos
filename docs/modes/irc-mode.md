# irc-mode, irc-servers-mode, and irc-channels-mode

compos ships a built-in rcirc-style IRC client with no external CLI dependencies. Each server, channel, and direct message gets its own buffer.

## Open

- `M-x irc`: open `irc-servers-mode` (default servers include Libera and OFTC via `irc-servers`).

## Keys in `irc-servers-mode`

| Key | What it does |
| --- | --- |
| `RET` | Connect to the server and open its buffer (or switch to it if already connected) |
| `a` / `d` | Add or remove a server entry |
| `k` | Disconnect |
| `g` / `q` | Refresh or quit |

## Inside a channel or server (`irc-mode`)

Type messages at the prompt at the bottom. Commands start with `/`: `/join #chan`, `/part`, `/msg nick text`, `/me action`, `/nick newnick`, `/list` (opens `irc-channels-mode`, where `RET` joins and `/` filters), and `/quit`. Run `M-x irc-toggle-verbose` to toggle showing raw server lines vs human messages only.

See also: [11. CONNECTED APPS](../11.%20CONNECTED%20APPS.md).
