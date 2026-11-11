# The handheld client

The handheld client is the editor on a phone. Open `/m` on the daemon. A
buffer link for a phone is `/m/b/NAME`, with the same `?line=N` query as a
desktop link.

The client is a second client of the same frame payload the desktop draws.
It attaches a frame, reads `Compos.Core.Editor.render_state/1`, and sends
every gesture as the same `key` event the desktop sends. No editor logic
lives in the client. The policy lives in
`scheme/packages/handheld.scm`.

## The screen

- **The modeline.** One line: the flags, the buffer name, the mode, the
  buffer's modeline info, and the pending prefix as a badge. A tap runs
  `modeline-expand`.
- **The window.** The frame's selected window. A chat buffer shows the
  agent transcript. A file buffer shows its lines, read-only. A rendered
  document shows its preview.
- **The rail.** A drag along the left edge moves point by line. Scheme
  moves point with `handheld-scrub!`. The rail is not shown for a chat.
- **The composer.** One field with three registers. A literal chord, such
  as `C-x b`, dispatches its keys. `M-x NAME` runs the command. Any other
  text goes to the group's chat as a message. `handheld-compose!` decides.
  While a prompt is open, the field feeds the prompt one key at a time.
- **The chips.** Commands above the field, one per context. Each chip shows the key
  bound to its command, or `M-x NAME` when nothing binds it. A tap sends
  the chord through the composer. `handheld-chips` names them.
- **The tab rail.** The groups in MRU order. A phone switches groups,
  not buffers. A tap on another group switches to it and shows its chat,
  founding the chat when the group has none. A tap on the current group,
  or a long press on any group, opens that group's buffers as a prompt
  sheet. `handheld-tabs` builds the rows, `handheld-tab!` answers the
  tap, and `handheld-tab-hold!` the press.
- **The chord key.** A tap opens the keys panel. Its tabs are the
  sections: `recent` for the commands the phone ran last, `plain` for
  unmodified keys, `C-` and `M-` for modified single keys, then one tab
  per prefix (`C-x`, `C-c`, `C-h`, ...). Each tab is a scrolling list of
  the bindings under it, with the command and the first line of its doc.
  A tap on a row presses the whole chord; a recent row runs by name.
  Typing in the filter field searches every command, bound or not:
  each term must match the key, the name, or the first doc line, in any
  order. A command with a key in this buffer comes first; the rest show
  `M-x` as their key. A tap on a match runs it by name. `handheld-search`
  builds the rows. When a prefix is already
  pending the panel opens on that tab and does not press the prefix
  again. `handheld-keys` builds the sections from the buffer's whole
  keymap ladder; a local key wins over a global one. `handheld-recents`
  reads the phone's own history and the desk's M-x history.
- **The sheets.** An active minibuffer renders as a sheet of rows. A tap
  on a row selects it and accepts. An active transient renders as a sheet
  of key boxes; a tap sends the key. Every prompt and every transient
  gets this for free.

## Files

- `apps/compos_ui/lib/compos/ui/mobile_live.ex` — the LiveView.
- `apps/compos_ui/lib/compos/ui/mobile_layouts.ex` — the root layout: the
  stylesheet and the `Handheld` hook.
- `scheme/packages/handheld.scm` — the policy.
- `scheme/packages/handheld-test.scm` — the policy tests.
- `apps/compos_ui/test/compos/ui/mobile_live_test.exs` — the view tests.

## Customs

- `handheld-prefixes` — `(KEY LABEL)` rows: the prefixes the keys panel
  lists first, after the families.

## Not built yet

- Answers do not report the chord they ran. The design's "pin to fan"
  receipt needs the agent to name the command it used.
- A left-handed placement of the chord key.
- Editing text in a file buffer. The handheld client reads files and
  talks to the chat; it does not edit prose.
