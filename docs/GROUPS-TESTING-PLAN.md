# Groups Testing Plan

Put point on a TODO heading and press `C-c C-t` to mark it done.
Put point inside the test block and press `C-c C-c` to run it.
Save this document with `C-x C-s`.

Each TODO now lists its **Run** command or shortcut. Use `M-x` followed by the exact command name when no shortcut is shown.

## Quick automated check

Run this after each section of manual testing:

```sh
mix test apps/aimax_core/test/aimax/group_switch_command_test.exs apps/aimax_core/test/aimax/desktop_restore_test.exs
```

## Creation and identity

### TODO Create an empty group

**Run:** `M-x group-new`

Confirm it remains available without buffers or chats.

### TODO Create a group from the current buffer

**Run:** `M-x group-new-from-buffer`

Confirm the current work buffer becomes a member.

### TODO Create a group from visible buffers

**Run:** `M-x group-new-from-visible`

Arrange several windows first and confirm every visible work buffer joins.

### TODO Cancel every creation prompt

**Run:** Run the relevant creation command, then `C-g`.

Confirm cancellation leaves groups and memberships unchanged.

### TODO Reject invalid names

**Run:** `M-x group-new`, then `M-x group-rename`.

Try an empty name and an existing name. Confirm neither creates a group.

### TODO Rename a populated group

**Run:** `M-x group-rename`

Confirm memberships, chats, metadata, and layouts remain attached.

### TODO Rename while the primary chat is active

**Run:** `M-x group-rename`

Confirm the active group and chat keep working under the new name.

## Membership operations

### TODO Pull an ungrouped buffer

**Run:** `M-x group-pull-buffer`

Confirm it joins the current group without changing frame context.

### TODO Pull a foreign buffer

**Run:** `M-x group-pull-buffer`

Confirm it gains shared membership and remains in its original group.

### TODO Pull the same buffer twice

**Run:** Run `M-x group-pull-buffer` twice.

Confirm the second pull is a no-op.

### TODO Pull several marked buffers

**Run:** `M-x group-pull-buffer`; mark with `SPC`, accept with `RET`.

Mark buffers in the switcher and pull them together.

### TODO Push one buffer to an existing group

**Run:** `M-x group-push-buffer`

Confirm the buffer joins the destination while the frame stays in the current group.

### TODO Push marked buffers to a new group

**Run:** `M-x group-push-buffer`; mark with `SPC`, choose **New group**.

Confirm the group is created once and receives every marked buffer.

### TODO Pop a shared buffer

**Run:** `M-x group-pop`

Confirm only its membership in the current group is removed.

### TODO Pop the visible buffer

**Run:** `M-x group-pop`

Confirm the window selects a safe replacement.

### TODO Pop the final work buffer

**Run:** `M-x group-pop`

Confirm the now-empty group still exists.

### TODO Move by composing push and pop

**Run:** `M-x group-push-buffer`, then `M-x group-pop`.

Confirm the buffer ends in the destination and leaves the source.

## Switching

### TODO Check narrow buffer switching

**Run:** `C-x b` (`M-x group-switch-to-buffer`).

Press `C-x b` inside a group. Confirm only current-group members appear.

### TODO Check broadened buffer switching

**Run:** `C-u C-x b`.

Press `C-u C-x b`. Confirm foreign and ungrouped buffers appear.

### TODO Select a foreign buffer from the broad switcher

**Run:** `C-u C-x b`.

Confirm membership and frame group do not change.

### TODO Switch groups

**Run:** `M-x group-switch`.

Press `C-x g` and confirm the destination layout restores.

### TODO Switch repeatedly between two groups

**Run:** `M-x group-switch` repeatedly.

Confirm current-group and previous-group tracking stays correct.

### TODO Switch with no current group

**Run:** `C-x b`.

Confirm ordinary buffer switching remains usable.

### TODO Stress the switcher with many unrelated buffers

**Run:** `C-x b`, then `C-u C-x b`.

Confirm narrow and broadened switching remain responsive and selectable.

## Layouts and preview

### TODO Restore a multi-window layout

**Run:** Arrange windows, then `M-x group-switch`.

Arrange two or three windows, leave the group, and return.

### TODO Restore split ratios

**Run:** Resize windows, then `M-x group-switch`.

Change window sizes, switch away, and confirm the ratios return.

### TODO Ignore transient UI when remembering layouts

**Run:** Open the transient UI, then `M-x group-switch`.

Open help, a popup, source view, or the groups board and confirm it does not replace the remembered work layout.

### TODO Cancel after previewing several candidates

**Run:** Start `C-x b` or `M-x group-switch`, preview candidates, then `C-g`.

Confirm the tree, selected window, buffer, point, and scroll position all return.

### TODO Kill the previewed candidate before cancellation

**Run:** Preview with `C-x b`, kill the buffer, then `C-g`.

Confirm cancellation heals safely.

### TODO Reenter the switcher during preview

**Run:** Start `C-x b` again while previewing.

Confirm restoration does not stack or corrupt the layout.

### TODO Restore with one killed layout buffer

**Run:** Kill one layout buffer, then `M-x group-switch`.

Confirm the remaining layout heals without resurrecting the killed buffer.

### TODO Restore with every layout buffer killed

**Run:** Kill all layout buffers, then `M-x group-switch`.

Confirm a safe default layout appears.

### TODO Keep different layouts in two frames

**Run:** In each frame, use `M-x group-switch`.

Use the same group in two frames and confirm each frame restores its own layout.

## Chats

### TODO Create the primary group chat

**Run:** `M-x group-chat-new`.

Confirm it belongs to exactly one group.

### TODO Create additional group chats

**Run:** `M-x group-chat-new`.

Confirm each chat has one owner and distinct chat identity.

### TODO Change the primary chat

**Run:** `M-x group-chat`.

Confirm group switching and chat commands use the new primary.

### TODO Kill the primary chat

**Run:** Use the normal buffer-kill command.

Confirm the group record and work-buffer memberships survive.

### TODO Reset a group chat

**Run:** Use the chat reset command, if available.

Confirm its `chat-id` and `group-id` survive the reset.

### TODO Cycle chat noise

**Run:** `M-x group-noise-cycle`.

Test `off`, `quiet`, and `loud`, including restart persistence.

## Lifecycle and failure handling

### TODO Dissolve a group with shared clean buffers

**Run:** `M-x group-dissolve`.

Confirm other memberships and buffers survive.

### TODO Dissolve a group containing modified buffers

**Run:** `M-x group-dissolve`.

Confirm modified buffers survive and normal protection remains active.

### TODO Kill a group containing a modified file

**Run:** `M-x group-kill`.

Confirm normal modified-file protection applies.

### TODO Cancel a group kill midway

**Run:** `M-x group-kill`, then `C-g` when prompted.

Confirm surviving buffers and partial results are reported clearly.

### TODO Delete a group referenced by another frame

**Run:** `M-x group-dissolve` or `M-x group-kill`.

Confirm stale current-group and previous-group references are cleared.

### TODO Discard a late description reply

**Run:** `M-x group-describe`, then `M-x group-dissolve`.

Request a description, dissolve the group before it returns, and confirm no deleted record is recreated.

### TODO Refresh the groups board during membership changes

**Run:** `M-x groups`; refresh with `g` or `M-x groups-refresh`.

Kill and move member buffers while refreshing; confirm the board stays consistent.

## Restart and migration

### TODO Restart with varied group state

**Run:** Restart ai-max, then `M-x groups`.

Use populated groups, an empty group, multiple chats, custom noise, and custom layouts.

### TODO Restore frame context after restart

**Run:** Restart, then `M-x group-switch`.

Confirm current-group and previous-group restore by stable ID.

### TODO Preserve IDs across restart and rename

**Run:** `M-x group-rename`, restart, then `M-x groups`.

Confirm group, chat, and membership identity does not depend on names.

### TODO Migrate a legacy name-based buffer

**Run:** Restore the legacy desktop state, then restart ai-max.

Restore a buffer with the old `group` local and confirm it gains stable membership.

### TODO Repeat restart after migration

**Run:** Restart ai-max again.

Confirm migration is idempotent.

### TODO Recover from malformed persisted state

**Run:** Restart ai-max with the malformed persisted state.

Try missing group records, duplicate memberships, invalid frame references, and invalid noise values.
