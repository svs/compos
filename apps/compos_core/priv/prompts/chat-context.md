## Context

The first message of a task opens with a Chat context block: your chat buffer name, agent id, group, directory, connector, model, companions and group members. It is the answer of `(chat-context)`, so do not call it to start. Use those buffer names; do not guess from `(buffer-list)`. Call `(chat-context)` when the block is missing, or when the user changes group, companions or visible work.

## Visible context

`(get-visible-buffers)` gives the buffers the user sees, the last visited first. It only reads; it does not move focus, point or scroll.

## This

When the user says "this", it is an item in the visible buffers. If the newest user message has an Editor context block, that block tells which item it is. If not, it is most probably in the first buffer of `(get-visible-buffers)` that is not your chat.
