# Sharing

Status: design. Nothing is built. Parent task: t-261121-123435-438.

## Goal

The owner shares single buffers with family members. The first use is
the Ruhaan Education group. Each person runs their own compos, and the
shared buffers are live in both.

## Rules

1. **Data crosses, execution never.** Only the content of shared buffers
   and their changes go between people. No command, Scheme, agent call
   or eval crosses.
2. **Run on your own compute.** A person reads and edits shared buffers
   with Scheme, commands and agents on their own machine and account.
   The owner's compos does no work for them except the sync.
3. **No leaks.** A person learns nothing about buffers that are not
   shared with them, not even that they exist.
4. **No lost writes.** Concurrent edits merge. Nothing is rejected.
5. **The buffer is the filesystem.** Each compos saves its copy to its
   own disk. The files agree because the buffers agree.

## Two links

| | Peer | Share |
|---|---|---|
| Between | the owner's own compos instances | the owner and other people |
| Trust | full: same person | data only |
| Wire | eval over the socket (`Compos.Core.Peer`, `peers.scm`) | three sync requests, nothing else |
| Use | orchestrate my machines, worktrees, daemons | shared buffers |

Peer stays as it is. Share is a separate listener on its own port
(`share-port`, default 4006), with its own code path. Nothing else is
mounted on that port: no editor, no LiveView, no static files, no
webhooks, no eval. A Share credential never opens Peer or the editor.

Why a port of its own:
- The editor (4004) and Peer can stay on loopback or the owner's own
  network. Only the share port is exposed to other people.
- A bug in the editor's routes or checks cannot reach the share port, and
  the reverse.
- The user can open, forward or firewall the one port, and turn sharing
  off by closing it.
- The app port (4005) already isolates app scripts the same way.

## Share

### Replicas

- A shared buffer has a Loro document in each compos (one per home, as
  today). The two exchange Loro updates.
- Each compos holds a full local copy. Every Scheme call on it is local.
- The copy appears in the receiver's compos in a group of its own named
  after the sharer, for example "svs: Ruhaan Education".

### The wire

Three requests, each for a buffer on the share list of the asking person:

```
what version do you have?     version token
what am I missing?            updates since a token
here is what you missed       updates to merge
```

- A request for a buffer that is not shared gets the same answer as a
  buffer that does not exist.
- Receiving updates only merges text. It runs no hook on the content.
- Sync is pushed on change, so the copies stay live.
- The route to the other host is not a concern of compos. Compos dials
  the address it is given. Tailscale, a VPN or a tunnel is the user's
  choice. The device key is the only check compos makes.

### Identity (the Telegram flow)

- **Person** `p-...`, **Device** `d-...` (a key the compos makes and
  keeps), **Share** (buffer or group, person, read or write),
  **Invite** (what it offers, expiry, uses).
- Pairing: the owner sends an invite. The other compos makes a device
  key and shows a code. The person tells the owner the code by a
  trusted channel. The owner types it to approve. A forwarded invite
  shows a different code.
- Each connection: challenge, signed by the device key, checked against
  a device that is not revoked.
- Revoke a device, a person or a share: the link drops at once.

### Read-only

The owner's compos ignores updates from a read-only person. Their copy is
read-only too, so they do not type into something that will not stick.

### Shared data is untrusted

- An agent treats text from a shared buffer as data, never as
  instructions.
- A shared todo starts no agent. A person starts the work.
- A code block in a shared buffer shows who changed it last, and running
  it asks first.
- No shared buffer is ever loaded as Scheme, a package or settings.

### Apps

- An app's list and detail pages are views. The data buffers are shared.
  Each person's installed app draws its own view.
- App code is not shared by sync. The owner publishes a package and the
  person installs it on purpose. An update is accepted on purpose too.
- The data format has a version. An older app keeps fields it does not
  know.
- App stores write small stable edits, one record at a time, so merges
  stay clean.

## Concurrent writes

- Text merges per character through Loro. Undo takes back only your own
  changes (PROVENANCE-CRDT.md, Phase 3).
- A file opened on two machines must share its history, not be seeded
  twice: the first share sends the owner's document, and the receiver
  starts from it (PROVENANCE-CRDT.md, Two machines, one file).
- Every change carries its person. Optional later: sign each change with
  the device key.

## Later

- A guest page for people without compos (device keys in the browser).
- Presence and remote cursors in shared buffers.

## Open questions

1. Share unit: single buffers, a group, or both?
2. Which apps does Ruhaan Education use, and where is their data today?
3. Read or write by default?
