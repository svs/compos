# Windows, panes, buffers, and groups: the specification

For a guide to the screen, read [WINDOWS.md](WINDOWS.md). This file is the
acceptance contract: rules and test cases.

## Status and authority

This is the acceptance contract for window behavior. It describes required results
in natural language. A listed case is not a claim that the implementation passes it.

The group-owned window registry is not yet verified. Older tests describe some
superseded behavior, including filling layouts from buffer recency and refilling
exhausted windows. Those expectations must change rather than define the product.

This document supersedes conflicting terminology and requirements in
the earlier window-history audit (`doc/WINDOWS.md`). Git history keeps that audit; the tree no longer has it.

## The model

- A **buffer** has at most one group owner and contains content: a document, directory listing, chat, or application surface.
- A **window** owns an ordered stack of buffers and their view state.
- A **pane** is a physical position in a frame's layout: main, left, right, and so on.
- A **frame** is one editor surface with a visible layout.
- A **group** owns its windows. A window has exactly one group owner, or is explicitly ungrouped.
- A **visible window** occupies a pane. An **invisible window** exists without occupying a pane.
- A **preferred window for a mode** receives new buffers of that mode within its group and frame. Existing buffers may occupy other windows.
- **Opening** chooses a destination window and brings a buffer to the top of its stack.
- **Displaying** may show a buffer without changing keyboard focus.
- **Closing a layer** removes its current display and reveals that window's own predecessor.
- **Killing a buffer** destroys its content identity everywhere. Closing a layer need not kill the buffer.
- **Degrading the layout** removes an exhausted window and gives its space to surviving windows.

A window keeps its identity when it changes panes, becomes invisible, or becomes visible again.
The renderer's pane handle is not the identity of the window stack.

In the examples, a window's stack is written from bottom to top. “A, B, C” means
C is visible, closing C reveals B, and closing B reveals A.

A buffer cannot belong to two groups. Explicit `group-add` or `group-move` can
change its owner. A layout, preview, or application launch cannot implicitly move it.
Ungrouped means no owner, not membership in every group.

**Current file behavior:** file visits reuse a canonical buffer by path.
An explicit group destination moves that buffer; it does not create a separate buffer.
Separate file buffers per group are a proposed extension below, not current behavior.

## Non-negotiable rules

1. Never pull a window or buffer from another group to fill the current layout.
2. Every automatic search uses the current group before considering mode, visibility, or recency.
3. Layouts arrange windows. They do not select individual buffers from those windows.
4. Unused layout capacity is permitted. It does not authorize opening more content.
5. A window's stack belongs to that window, including while invisible.
6. Consolidation uses the window the user is in and keeps it visible in its existing pane.
7. Non-mode buffers displaced by consolidation move to an invisible window, preserving their order.
8. Consolidation removes that mode from other scoped stacks and return records at the time of the command. Later explicit moves are allowed.
9. New buffers use the mode's preferred window. Reveal that window if hidden. Explicit buffer moves do not change the preference.
10. Closing consults only the closing window's own remaining stack.
11. If no eligible predecessor exists, degrade the layout. Do not borrow from group recency or another window.
12. Focus changes, redraws, failed operations, and passive background work do not rewrite window history.
13. Restoring a saved layout does not bypass ownership, mode consolidation, or buffer-lifetime checks.
14. Every user-facing display path follows the same rules, including application commands and agent actions.

## Test setup and observations

Use distinguishable buffer names, modes, groups, and content. Include multiple
buffers of one mode, unrelated modes, an invisible window, and another group.

Before and after each action, check the following where relevant:

- Logical window identities and group ownership.
- Visible pane assignments, pane order, and geometry.
- The selected window and its visible buffer.
- Every affected window's complete ordered stack, including invisible windows.
- Buffer liveness and content identity.
- Cursor position, scrolling, and follow state for affected views.
- Active layout target and saved group arrangement.
- Outstanding return records, preview ownership, and mode destinations.

Do not infer success from the visible buffers alone. A chat hidden beneath a
Dired buffer in the wrong window is still a consolidation failure.

## How to execute the cases

The **Command or trigger** column names the command under test.
Invoke bare command names with `M-x`; key sequences are shortcuts for those commands.
`C-x 0` invokes `delete-window`. It removes a window; it is not the same operation as
`quit-window`, which first tries to reveal the window's predecessor.
`C-x l` starts layout selection. `C-backtick` invokes `group-next-mode-buffer`: it walks the group's buffers of the current buffer's mode. Cmd-down and Cmd-up invoke `group-next-buffer` and `group-previous-buffer`: they walk every buffer of the group.

`window-left/right/up/down` should move the whole window stack.
`buffer-left/right/up/down` should move only the current buffer.
`focus-left/right/up/down` only change selection.
`window-swap!` moves both logical windows between panes, stacks included.

**API** marks an existing Scheme function without a dedicated interactive command.
**Harness** marks a controlled event, corrupted fixture, or lifecycle test without a user command.
**Proposed** marks an unimplemented command or changed behavior.
A command's existence does not mean it passes the required result.
Set up unusual histories in a disposable test frame, then invoke the listed command.

## 1. Window identity and ownership

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| I01 — Move a window | `window-right` / `window-left` (repeat with `window-up` / `window-down`) | Move a window containing A, B, C from the left pane to the right pane. | The same window arrives with C visible and B and A underneath. Its ownership and view state remain attached. |
| I02 — Move a buffer | Visit B in the source, then `buffer-left` / `buffer-right` (repeat vertically) | Explicitly move B from one window into another. | Only B moves. The source and destination windows retain their identities and remaining stacks. |
| I03 — Make invisible | **Proposed:** `window-hide`; `C-x 0` tests window deletion separately | Hide a window containing A, B, C. | The window retains its identity, group, stack, and view state. It occupies no pane. |
| I04 — Reveal an invisible window | **Proposed:** `(hidden-window-show! ID)`; no reveal API or command exists | Explicitly show that window in a pane. | The same window becomes visible with C on top and its remaining stack intact. |
| I05 — Exchange windows | **Proposed:** `(hidden-window-show! ID)` | Show an invisible window in an occupied pane. | The incoming window occupies that pane. The displaced window becomes invisible with its own stack intact. |
| I06 — Separate identities | `split-window-right` (`C-x 3`); `other-window` (`C-x o`) | Create two explicitly independent views of one buffer in the same group. | The views have separate window identities and independent cursor and history state. Sharing content does not merge the windows. |
| I07 — One buffer, one group | `group-add`, then `group-move`; **API:** `buffer-add-group!`, `buffer-move-to-group!` | Put a buffer in A, then explicitly move it to B. | B becomes its only group. A loses membership. Opening content elsewhere must not create a second membership. |
| I08 — Focus is not ownership | `focus-left` / `focus-right`; `other-window` | Focus a different window or an ungrouped utility surface. | Existing windows keep their owners. Ownership is not recalculated from the last selected buffer. |
| I09 — Cover is not ownership | `describe-mode`, then `quit-window` | Temporarily display help over a group-owned window. | The window still belongs to its original group. The cover does not reassign it. |
| I10 — Renderer handles change | `window-layout-columns` (`C-x l c`), then `window-layout-rows` (`C-x l r`) | Rebuild the visible layout so pane handles change. | The logical windows retain their identities, owners, stacks, and consolidated-mode assignments. |

## 2. Group boundaries

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| G01 — Visible foreign match | `switch-to-buffer` (`C-x b`), choose A’s chat | Group A has no chat window. Group B has a visible chat window. Open a chat belonging to A. | Use or create a window owned by A. B's window does not move or change. |
| G02 — Invisible foreign match | `switch-to-buffer` (`C-x b`), choose A’s chat | Repeat G01 with B's chat window invisible. | B's invisible window is not a candidate. Its state is unchanged. |
| G03 — Foreign recent buffer | `window-layout-columns` (`C-x l c`) | A layout in A has spare capacity. The most recently used hidden buffer belongs to B. | The layout stays under capacity. B's buffer does not appear. |
| G04 — Same mode across groups | `mode-consolidate` | Both groups have chats. Consolidate chats in A. | Only A's scoped chat stacks change. B's visible and invisible windows remain unchanged. |
| G05 — Other frame | `switch-to-buffer` in the current frame; **harness:** second-frame fixture | A matching window is visible in another frame under another group. | Automatic routing in the current frame does not steal, move, or mutate it. |
| G06 — Explicit group switch | `group-switch`, choose B | The user explicitly switches from A to B. | A's windows remain owned by A and are saved. B's own arrangement is restored. This is navigation, not borrowing. |
| G07 — Return to a group | `group-switch`, choose A | Switch back from B to A. | A's own windows return with their identities, stacks, and mode destinations. No B history is attached to them. |
| G08 — Stale saved foreign entry | `group-switch`, choose A; **harness:** stale saved layout | A's saved arrangement names a buffer that now belongs only to B. Restore A. | Exclude the foreign entry and reduce the arrangement as necessary. Do not load it temporarily and then repair it. |
| G09 — Foreign history entry | `group-switch`, then `quit-window`; **harness:** foreign history | A's saved window has an eligible visible buffer but a foreign buffer deeper in its stack. | Restoration removes the ineligible history entry. Closing later cannot reveal it. |
| G10 — Ungrouped work | `remove-group-from-buffer`, then `mode-consolidate` in an ungrouped frame | Open or consolidate a mode while explicitly ungrouped. | Only ungrouped windows and eligible ungrouped buffers participate. No group becomes an implicit donor. |
| G11 — Global utility | `ibuffer`; **proposed group-local utility routing** | Display an eligible ungrouped utility, such as a buffer browser, in a group's context. | The hosting window retains its owner. The utility does not import another group's window or history. |
| G12 — Pinned group | `group-pin`, then `switch-to-buffer`, `quit-window`, `window-layout-columns` | Keep A pinned while another group's buffer is more recent. Open, close, and relayout in A. | Pinning does not authorize foreign content. Every candidate still passes the ownership check. |
| G13 — Membership removed | `remove-group-from-buffer`, then `group-switch` and `quit-window` | Remove a buffer's membership in its window's group. | Future routing and restoration reject that buffer for that group. No stale history or saved layout restores it there. |
| G14 — Group deleted | **API:** `group-kill!` / `group-dissolve!`; then `group-switch` | Delete a group with invisible windows and mode assignments. | Its records cannot be reused under a different group or revive through stale identifiers. |
| G15 — Background group work | **Harness:** agent buffer edit in B while A is selected | An agent modifies a buffer in B while the user works in A. | A's windows, layout, stacks, and focus do not change. |

## 3. Opening and destination selection

There are two layout states: the frame already has its target arrangement, or it
does not. Both states use the same group ownership and mode-destination rules.
The target affects placement, not which group supplies the window.

For a newly opened mode buffer, use its group's preferred logical window.
Reveal that same window if it is invisible, then display the new buffer there.
A different visible window showing the same mode does not take precedence.

When no preference exists, normal group-scoped placement chooses a window and
registers it as that mode's preferred window. This is the default establishment rule.
An explicit preference command can change it without moving existing buffers.
`window-mode-preference` sets the selected pane's preferred mode. It steers routing only.

Users may move existing buffers with `buffer-left/right/up/down` or explicitly
show them in another same-group window. Those actions do not retarget future opens.
Revisiting such a buffer uses its existing window. Changing layouts preserves those choices.
Moving the preferred window itself carries its preference to the new pane.

Consolidation gathers the mode's buffers once and makes the selected window preferred.
It does not impose a permanent restriction on later buffer placement.

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| O01 — Mode already visible | `switch-to-buffer` (`C-x b`), choose the second chat | Open a new chat while the group's preferred chat window is visible. | Put the new chat in the preferred window's stack. Preserve any explicitly placed chats elsewhere. |
| O02 — Mode invisible | `switch-to-buffer`, choose a buffer in the invisible destination | Open a chat whose destination window is invisible. | Reveal that same window according to the placement policy. Do not manufacture another stack for the mode. |
| O03 — Target already reached | `switch-to-buffer` after `C-x l c` reaches its target | The layout is at its target and the preferred window is visible. Open a new buffer of that mode. | Use that destination without changing the layout merely because another buffer was opened. |
| O04 — Target not reached | `switch-to-buffer` after `C-x l c` remains below target | The layout is below its target. Open another buffer of an existing mode. | Reuse that mode's window. Spare capacity does not justify a duplicate. |
| O05 — New mode | `find-file` (`C-x C-f`) or `switch-to-buffer` for the new mode | Open a new buffer whose mode has no registered preference in the current group. | Choose an eligible group-local window, creating one if needed, and register it as preferred. Do not take another group's window. |
| O06 — Full layout, new window | `find-file` / `switch-to-buffer` after `C-x l 2` fills both panes | A new mode requires a window while the target has no spare pane. | Apply the window placement policy within the group. If a window is displaced, preserve it as an invisible window rather than grafting its stack onto the new one. |
| O07 — Buffer already visible | `switch-to-buffer`, choose the current buffer | Open the buffer already at the top of its destination. | Select it when requested. Do not add a duplicate layer or reset its view. |
| O08 — Buffer already in stack | `switch-to-buffer`, choose a hidden predecessor | Explicitly visit a buffer below the current buffer in its destination. | Bring it forward within that same window. Do not open it in another pane because it was hidden. |
| O09 — Passive display | **API:** `(display-buffer BUFFER)` | Show a result in another eligible window without requesting focus. | The destination records its own predecessor. Focus stays in the original window. |
| O10 — Selected display | **API:** `(layout-target-open! BUFFER #t #f)` | Show the same result and request focus. | Use the same destination as O09, then select it. Destination choice and focus are separate decisions. |
| O11 — Explicit destination | **API:** `(display-buffer-in-window! WINDOW BUFFER)` | A caller requests a particular window while another window is selected. | Validate group ownership. An explicit user placement may override the mode preference for that buffer. Record only the actual destination's history. |
| O12 — Incompatible explicit destination | **API:** `(display-buffer-in-window! WINDOW BUFFER)` with an incompatible destination | A caller requests a window in another group. | Reject the foreign destination. A same-group window is not incompatible merely because another window is preferred for the mode. |
| O13 — Other-window constraint | **API:** `(display-buffer BUFFER (list 'inhibit-same-window #t))` | The preferred window is selected, but the user explicitly requests another window. | Use an eligible same-group window for this explicit placement. Keep the preference unchanged. If none is available, report the conflict. |
| O14 — Source differs from destination | `dired-visit` / `notmuch-preview` from the source listing | An action in a listing opens a buffer in another window. | The opened buffer covers the destination's predecessor, not the listing merely because the listing initiated the action. |
| O15 — No mode information | **API:** `buffer-create`, then `switch-to-buffer!` before mode setup | Open a buffer whose mode has not been established. | Do not infer its destination from stale history or an unrelated buffer's mode. Any provisional window remains group-scoped. |
| O16 — Mode setup changes | **API:** `set-mode!` after buffer creation; **harness:** deferred setup | Mode setup completes after a buffer is created. | Resolve the now-known mode through the same routing policy. Do not create an additional destination during setup. |
| O17 — Parent-mode preference | `window-mode-preference`, then `switch-to-buffer` for a derived mode | A window explicitly prefers a parent mode and a compatible derived-mode buffer opens. | Apply the declared compatibility rule consistently to routing, cycling, and consolidation. |
| O18 — Failed open | `find-file`; **harness:** load failure or rejected destination | Loading fails or the destination request is rejected. | Preserve all existing windows, stacks, ownership, layout, and focus. |

### Preferred-window acceptance cases

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| W01 — Establish preference | Open a new mode buffer through its normal command | No preference exists for this mode in the group. | Register the chosen logical window as preferred. Leave other groups unchanged. |
| W02 — New buffer | Open another new buffer of that mode | The preferred window is visible, but another window is selected. | Display the new buffer in the preferred window. |
| W03 — Hidden preferred window | **Proposed:** `window-hide`, then open a new mode buffer | The preferred window is invisible. | Reveal the same window with its existing stack and add the new buffer there. |
| W04 — Move an existing buffer | `buffer-right` / `buffer-left` | Move a chat out of the preferred chat window. | Honor the move. Retain the original preferred window for future chats. |
| W05 — New buffer after a move | Open a new chat after W04 | Both windows now contain chats. | Route the new chat to the original preferred window. |
| W06 — Revisit a moved buffer | `switch-to-buffer`, select the moved chat | The chat remains in its explicitly chosen window. | Select and reveal it there. Do not move it back to the preferred window. |
| W07 — Change preference | `window-mode-preference` in the selected window | Choose a new preferred window for chat-mode. | Future new chats use that window. Existing chats stay where they are. |
| W08 — Move the preferred window | `window-right` / `window-left` | Move the whole preferred window to another pane. | The preference follows the logical window and its stack. |
| W09 — Consolidate, then move | `mode-consolidate`, then `buffer-right`, then open a new chat | Move one chat away after consolidation. | Keep the explicit move. Send the new chat to the consolidated window. |
| W10 — Layout after a move | `C-x l c` / `C-x l r` after W09 | Change geometry after explicitly separating chats. | Preserve both stacks. Do not consolidate automatically. |
| W11 — Visible alternative | Open a new chat | The preferred chat window is hidden; another chat window is visible. | Reveal and use the preferred window. Do not substitute the visible alternative. |
| W12 — Preferred window destroyed | `C-x 0`, then open a new mode buffer | Delete the preferred logical window, rather than hide it. | Remove the stale preference. Choose a group-local destination and establish a new preference. |
| W13 — Restore preference and moves | **Harness:** desktop save and restore | Save a hidden preferred window and a manually moved buffer elsewhere. | Preserve both the preference and the explicit placement. A new buffer reveals the preferred window. |

## 4. Mode consolidation

The default scope is the current group in the current frame. The destination is
the selected window and the mode is that window's declared or automatic preference.

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| M01 — Basic consolidation | `mode-consolidate` | Two windows in the group contain chats. Run mode-consolidate in one. | All scoped chat buffers belong to the selected destination stack. The selected chat stays visible. |
| M02 — Preserve destination | `mode-consolidate` | Consolidate while the destination occupies the main pane. | Keep that logical window visible in the main pane and keep focus there. Do not replace it with a newly created window. |
| M03 — Hidden chat under Dired | `mode-consolidate` | Another window shows Dired with a chat underneath. Consolidate chats. | Remove the chat from that window's history. Keep Dired and its non-chat predecessors there. |
| M04 — Many levels deep | `mode-consolidate` | Chats occur at several depths among another window's non-chat buffers. | Remove every scoped chat entry, not only the first predecessor. Preserve the order of the remaining entries. |
| M05 — Destination has non-mode buffers | `mode-consolidate` | The selected chat window contains documents or listings beneath its chats. | Move those non-chat buffers together into an invisible window. The chat destination becomes mode-only. |
| M06 — Invisible means invisible | `mode-consolidate` | Consolidation creates the window in M05. | Do not split a pane, open the displaced stack, or change focus to it. |
| M07 — Preserve displaced order | `mode-consolidate` | The destination's displaced non-mode buffers have an established order. | Their invisible window retains that order. Revealing it later returns the same top buffer and remaining stack. |
| M08 — Invisible source | `mode-consolidate` | Another invisible window contains chat buffers. | Transfer its scoped chat entries to the destination. Keep its unrelated entries invisible. |
| M09 — Empty invisible source | `mode-consolidate` | An invisible window contains only the transferred chats. | Remove the empty window record. It must not remain a reusable ghost window. |
| M10 — Open but unshown buffer | `mode-consolidate` | A scoped chat is open but belongs to no currently visible stack. | Include it in the consolidated destination. Do not create a visible pane for it. |
| M11 — Duplicate occurrences | `mode-consolidate` | A chat occurs in multiple source histories. | Consolidation does not leave a copy in another source or accidentally create multiple destination windows. Preserve meaningful return-layer semantics within the destination. |
| M12 — Source has a predecessor | `mode-consolidate` | A source shows a transferred chat above unrelated work. | Reveal that source's own unrelated predecessor. Do not borrow a replacement. |
| M13 — Source becomes empty | `mode-consolidate` | A source has no buffers left after transfer. | Remove that exhausted window and let the visible layout shrink. Do not create a blank placeholder. |
| M14 — No buffer destruction | `mode-consolidate` | Consolidate and then inspect all transferred and displaced buffers. | Their content identities remain alive. Consolidation moves membership between windows; it does not kill content. |
| M15 — Repeat consolidation | `mode-consolidate` | Run the command again without intervening changes. | Do not create more invisible windows, duplicate stack entries, reorder the result, or change the layout. |
| M16 — Foreign mode buffers | `mode-consolidate` | Another group has chats, including chats with similar names. | Do not include those windows or buffers in the operation. |
| M17 — Return records | `mode-consolidate` | A source's quit or preview record still points to a transferred chat. | Remove or rewrite that stale return route. Later dismissal cannot resurrect the chat in that source. |
| M18 — Later open | `mode-consolidate`, then `switch-to-buffer` for a new chat | After consolidation, open a new chat in the group from a different pane. | It joins the consolidated destination. It does not start a new chat stack. |
| M19 — Later layout change | `mode-consolidate`, then each `C-x l` layout command | After consolidation, select each of the five layouts. | The consolidated window remains one window. Its internal chats do not become individual tiles. |
| M20 — Restore after consolidation | `mode-consolidate`, `group-switch` away and back; **harness:** desktop restore | Switch groups or restore the desktop after consolidation. | The mode destination and separated invisible stacks survive. Old saved layouts do not reintroduce pre-consolidation duplicates. |
| M21 — No eligible buffers | `mode-consolidate` | Run consolidation when the preferred mode has no eligible buffers. | Leave state unchanged and report that there is nothing to consolidate. |

## 5. Cycling within a mode

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| Y01 — Two buffers | `group-next-mode-buffer` (`C-backtick`), repeatedly | Press C-backtick repeatedly in a window with two eligible mode buffers. | Alternate between those buffers in the same window. |
| Y02 — Several buffers | `group-next-mode-buffer` (`C-backtick`), repeatedly | Cycle through several buffers of the current buffer's mode. | Follow a stable traversal order for that cycling session. Do not bounce between only the two newest entries. |
| Y03 — Other modes excluded | `group-next-mode-buffer` (`C-backtick`) | The group also contains files, chats, and directories of other modes. | They do not enter this window's mode cycle. |
| Y04 — Other groups excluded | `group-next-mode-buffer` (`C-backtick`) | Another group's buffer has the same mode and is more recent. | It does not enter the cycle. |
| Y05 — Focus preserved | `group-next-mode-buffer` (`C-backtick`) | Cycle while another pane shows a related buffer. | Cycling stays in the selected logical window and does not jump to the other pane. |
| Y06 — After consolidation | `mode-consolidate`, then `group-next-mode-buffer` (`C-backtick`) | Cycle chats after consolidating them. | Without intervening moves, all consolidated chats are reachable in the destination. Cycling must not undo later explicit moves or recreate stale source history. |
| Y07 — Explicit preference | `window-mode-preference`, then `group-next-mode-buffer` | Set an explicit mode preference for the pane. | The walk still follows the current buffer's major mode. The preference steers routing only. |
| Y08 — Temporary cover | `describe-mode`, then `group-next-buffer` | Help covers the mode window. Invoke its mode cycle. | Use the underlying window preference rather than treating help as a new owner of that window. |
| Y09 — Buffer killed mid-cycle | `group-next-buffer`; **harness:** kill a candidate before the next invocation | Kill a candidate while a cycle is in progress. | Skip the dead identity without selecting a foreign buffer or corrupting the cycle position. |
| Y10 — New cycle after another command | `group-next-buffer`, `next-line`, then `group-next-buffer` | Run another command between cycle presses. | Start the next cycle from the current state using the documented recency order. |

## 6. Layout selection and degradation

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| L01 — One window, columns target | `window-layout-columns` (`C-x l c`) | Select a three-column target while only one eligible window exists. | Keep one visible window. Do not open two more buffers to fill the target. |
| L02 — Two windows, columns target | `window-layout-columns` (`C-x l c`) | Select columns with two eligible windows. | Arrange those two windows. The third position remains unused. |
| L03 — Hidden buffers inside a window | `window-layout-columns` (`C-x l c`) | Select a layout while one window contains many hidden chats. | Treat the stack as one window. Do not select individual chats for spare panes. |
| L04 — Invisible same-group windows | `window-layout-rows` (`C-x l r`) | Select a different layout without explicitly asking to reveal invisible windows. | Rearrange the visible windows only. Invisible windows remain invisible. |
| L05 — Invisible foreign windows | `window-layout-columns` (`C-x l c`) | Select a layout while another group owns invisible windows. | They remain in the other group, untouched. |
| L06 — Global recency changes | `window-layout-columns` (`C-x l c`); **harness:** change recency headlessly | Touch hidden buffers or run background work, then select the same layout. | The visible window set does not change because recency changed. |
| L07 — Change geometry | `C-x l r`, `C-x l c`, `C-x l 2`, then `layout-forward` | Change rows to columns or two-pane, then scroll the panes. | Each window carries its own stack, ownership, cursor, and return state into its new pane. |
| L08 — Main direction | **Proposed:** `C-x l` plus each arrow | Choose each main-pane direction using the layout shortcuts. | The arrow names the main pane's position. Window stacks are not reversed or exchanged accidentally. |
| L09 — Smaller target | `window-layout-two-pane` (`C-x l 2`) from a larger arrangement | Select a target with fewer panes than the current arrangement. | Preserve surplus windows as invisible windows owned by the same group. Do not merge their histories into survivors. |
| L10 — Focus under smaller target | `other-window`, then `window-layout-two-pane` (`C-x l 2`) | Reduce the target while a later window is selected. | Preserve the selected logical window according to the stated main/focus policy. Do not silently discard it because it was late in traversal order. |
| L11 — Empty source removed | `mode-consolidate` / `quit-window`; also test `delete-window` (`C-x 0`) | Consolidation or quitting exhausts a window. | Remove it and let the layout use fewer windows. Preserve survivors' stack identities. |
| L12 — No compensating fill | `quit-window` after exhausting its own history | After L11, the group still has hidden buffers and invisible windows. | Do not refill the removed pane automatically. |
| L13 — Manual geometry | Drag a pane divider, then `switch-to-buffer` for the same mode | Resize panes before opening another buffer of an existing mode. | Reusing the mode destination does not rebuild or resize the layout. |
| L14 — Same target again | `window-layout-columns` (`C-x l c`) twice | Select the active target again without changing the window set. | No window is replaced by a hidden buffer. Histories and focus remain intact. |
| L15 — Preview layout | `window-layout` (`C-x l`), move through candidates | Move through layout choices in the chooser. | Preview geometry using the current eligible windows. Do not import buffers or commit ownership changes. |
| L16 — Cancel preview | `window-layout` (`C-x l`), then `keyboard-quit` (`C-g`) | Cancel the layout chooser. | Restore the exact prior windows, stack order, views, focus, and target. |
| L17 — Commit preview | `window-layout` (`C-x l`), accept with `RET`, then `winner-undo` | Accept a previewed layout. | Commit one layout change. Undo does not walk through every intermediate preview. |
| L18 — Stale cache | `window-layout-columns`; **harness:** stale cached slot order | The cached slot order differs from the actual visible window arrangement. | Preserve logical window identity and the user's current arrangement. Do not move stacks based on stale buffer-name caches. |
| L19 — Repeated buffer views | `window-layout-rows`; **harness:** independent duplicate views | Two explicitly independent windows show the same buffer with different histories. Retile them before consolidation. | Match by window identity, not buffer name. Neither history replaces the other. |
| L20 — Explicit foreign ID | **API:** `tile-windows!` compatibility path; **proposed:** logical-window-ID layout API | A layout caller supplies a window ID owned by another group. | Reject that window. Never transfer its ownership or show it temporarily. |

## 7. Closing, quitting, and buffer lifetime

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| Q01 — One cover | `quit-window` | A window contains A, B. Close B. | Reveal A in that same window. |
| Q02 — Nested covers | `quit-window` twice | A window contains A, B, C. Close twice. | Reveal B, then A. Consume each return layer once. |
| Q03 — Independent stacks | `quit-window` in each window | Left contains A, B; right contains X, Y, Z. Close in either window. | Only that window's stack advances. |
| Q04 — Same buffer visited again | `switch-to-buffer` for A, B, A; then `quit-window` repeatedly | Visit A, then B, then A again in one window. | Closing follows the recorded layers without accidental MRU deduplication or oscillation. |
| Q05 — No predecessor | `dired-quit` (`q` in Dired) | Quit a listing whose window has no eligible predecessor while another window survives. | Close the exhausted window and shrink the layout. |
| Q06 — Plenty of unrelated candidates | `dired-quit` (`q`) | Repeat Q05 with many recent buffers in the group. | Still close the window. Group recency is not a fallback. |
| Q07 — Foreign candidates | `dired-quit` (`q`) | Repeat Q05 when another group has matching buffers and windows. | They remain untouched. |
| Q08 — Invisible candidates | `dired-quit` (`q`) | Repeat Q05 with an invisible same-group window available. | Leave it invisible. Closing does not implicitly reveal it. |
| Q09 — Last window | `quit-window` in the sole visible window | Quit the final visible window when it has no predecessor. | Preserve the final window and report that no predecessor exists. Do not borrow a buffer or kill its last visible content as a side effect. |
| Q10 — Dired after chat consolidation | `mode-consolidate`, `other-window`, then `dired-quit` (`q`) | Consolidate chats, select Dired that formerly covered a chat, then press its quit command. | Reveal only Dired's remaining non-chat history. If none remains, remove the Dired window. No chat appears there. |
| Q11 — Several Dired levels | `mode-consolidate`, then repeated `dired-quit` (`q`) | Consolidate chats beneath several directory listings, then quit repeatedly. | Traverse the remaining directory history, then remove the exhausted window. Never return to a transferred chat. |
| Q12 — Stale quit record | `quit-window`; **harness:** stale quit record | The ordinary stack has been cleaned, but an older quit record names a transferred buffer. | The stale record cannot restore that buffer or recreate its old window. |
| Q13 — Global kill | `kill-buffer` (`C-x k`) | Kill a buffer appearing in several stacks. | Remove that buffer identity from every affected stack independently. Do not transplant one window's predecessor into another. |
| Q14 — Kill hidden predecessor | `kill-buffer` on B, then `quit-window` on C | Kill B beneath C in a stack A, B, C. Then close C. | Skip dead B and reveal the next valid predecessor from that same stack. |
| Q15 — All predecessors dead | `kill-buffer` on each predecessor, then `quit-window` | Kill every predecessor and then quit the current layer. | Degrade the layout. Do not refill from unrelated recency. |
| Q16 — Rename predecessor | `buffer-rename`, then `quit-window` on the cover | Rename A while B covers it, then close B. | Reveal the same renamed buffer identity. Update visible, invisible, saved, and return-state references. |
| Q17 — Name reused | `kill-buffer`, `buffer-new` with the old name, then `quit-window` on the cover | Kill hidden A, then create a different buffer with the same name. Close the cover. | Do not treat the new buffer as the old predecessor merely because its name matches. |
| Q18 — Unsaved edits | `quit-window`; cancel any save decision with `C-g` | Quit a modified file that requires a save decision. | Follow the existing save/cancel contract. A cancellation changes no window state. |
| Q19 — Repeated cleanup | **Harness:** invoke the same dismissal callback twice | A dismissal callback fires twice. | The second callback does not consume another layer or close a repurposed window. |
| Q20 — Predecessor also visible | `quit-window` with the predecessor visible elsewhere | A valid predecessor is already visible in another window, including after an explicit move following consolidation. | Restore the recorded predecessor rather than substitute a less-related buffer merely to avoid duplicate views. |

## 8. Temporary displays and previews

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| P01 — Borrowed preview | `dired-visit` (`RET`), change preview rows, then `dired-quit` (`q`) | Preview a result over a window showing X. Replace the preview several times, then dismiss it. | Restore X and its view. Preview replacements do not create unrelated permanent history. |
| P02 — Preview-created window | `dired-visit`, then `dired-quit` | A preview creates a temporary window, then is dismissed. | Remove only the temporary window it still owns. |
| P03 — Nested temporary covers | **Harness:** nested temporary display; then `quit-window` twice | Another temporary layer covers the original preview. | Closing the top layer reveals its predecessor. Final dismissal still knows which temporary window may be removed. |
| P04 — Existing buffer preview | `dired-visit` on an existing buffer, then `dired-quit` | Preview a buffer that already existed before the preview. | Dismissing the preview does not kill that pre-existing buffer. |
| P05 — Keep preview | `dired-open` on the previewed file | Keep a preview as ordinary work. | Adopt its window/history correctly. Later closing follows ordinary stack rules. |
| P06 — Open preview in source | `dired-open` from the source listing | Explicitly open the preview in the listing's window. | First restore or remove the preview destination appropriately. Record the listing as the source window's predecessor. |
| P07 — Dired with active preview | `dired-quit` (`q`) twice | Press Dired's quit command while its preview is active. | Dismiss the preview first. A later quit unwinds or closes the Dired window itself. |
| P08 — Delayed preview | `dired-visit`, then `group-switch`; **harness:** delayed callback completion | Schedule a preview, then switch group or repurpose its destination before it completes. | The old callback does not display into the new group or overwrite the repurposed window. |
| P09 — Temporary cover and preference | `describe-mode`, then `switch-to-buffer` for another chat | Show help over a chat window, then open another chat. | Use the chat window's existing preference and ownership. Help does not create another chat destination. |
| P10 — Listing is not automatically temporary | `dired` / `notmuch`; then `window-mode-preference` to inspect preference | Open a persistent directory or application listing. | Keep its own mode preference. Read-only or special-mode status alone does not make it a temporary cover of unrelated work. |
| P11 — Explicit temporary surface | **API:** set `window-preference-cover`, then `display-buffer` and `quit-window` | Mark an application surface as a temporary preference-preserving cover. | It follows the same return and ownership rules as help. |
| P12 — Cross-group preview | `dired-visit` / `notmuch-preview`; **harness:** foreign-owned destination | Request a preview that would import another group's owned window. | Reject that destination or require explicit group navigation. Preview is not an ownership exception. |

## 9. Invisible windows and persistence

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| H01 — Single registry | **Harness:** inspect visible and invisible logical records; registry inspection API pending | Inspect visible and invisible windows. | Both are records in the same identity and ownership system. Visibility is a property, not a separate kind of buffer history. |
| H02 — Hidden stack survives commands | `mode-consolidate`, then `switch-to-buffer`, `quit-window`, `group-next-buffer` | Create an invisible stack, then open, close, and cycle visible buffers. | The invisible stack remains intact unless an explicit operation targets its entries. |
| H03 — Reveal preserves geometry | **Proposed:** `(hidden-window-show! ID)` | Explicitly reveal an invisible window in an existing pane. | Exchange the window occupying the pane without creating or resizing a pane. |
| H04 — Wrong-group reveal | **Proposed:** `(hidden-window-show! FOREIGN-ID)` | Request an invisible window owned by another group. | Reject the request without modifying either group. |
| H05 — Save and restart | **Harness:** desktop save and restore in a disposable session | Save visible and invisible windows, restart, then inspect them. | Restore owners, logical IDs, stack order, mode destinations, visibility, and available view state. Runtime pane handles may differ. |
| H06 — Save without group switch | `mode-consolidate`; **harness:** immediate desktop save and restore | Consolidate and save the desktop immediately. | The active group's latest registry state is saved without requiring a group switch first. |
| H07 — Code reload | `reload-file`; **harness:** reload changed window definitions | Reload the window implementation during use. | Existing windows and hidden stacks survive. Defaults do not overwrite live registry state. |
| H08 — Missing buffer at restore | `kill-buffer`; **harness:** restore saved desktop with that missing buffer | A saved stack contains a buffer that no longer exists. | Remove the dead entry. Keep remaining valid entries in order or remove the exhausted window. |
| H09 — Ownership changed at restore | `group-move`; **harness:** restore the older saved desktop | A saved buffer has moved exclusively to another group. | Sanitize both current and hidden entries before showing the window. |
| H10 — Older desktop format | **Harness:** restore a desktop fixture using the old hidden-window format | Restore a desktop with the former separate hidden-stack records. | Migrate them once into the shared registry without duplicating windows or importing them into another group. |
| H11 — Reused runtime handle | `delete-window` (`C-x 0`), then `split-window-right`; **harness:** reused pane handle | A new pane receives a handle formerly used by another window. | Old ownership, quit records, and asynchronous callbacks do not attach to it. |
| H12 — Window hidden by smaller layout | `C-x l 2`; **harness:** save/restore; **Proposed:** `hidden-window-show!` | Reduce the layout, save, restart, then explicitly reveal a surplus window. | The same group-owned stack is still available. |
| H13 — Group arrangement saved earlier | `mode-consolidate`, then `group-switch` away and back | A group's old geometry predates consolidation. Restore it after consolidation. | Geometry restoration respects current window identity and mode preferences instead of splitting the consolidated stack back into buffers. |
| H14 — Focus on restoration | `other-window`; **harness:** desktop save and restore | Save with a non-first window selected, then restore. | Restore that logical selection when it survives; otherwise choose a deterministic surviving window of the same group. |

## 10. View state and non-displaying work

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| V01 — Cursor and scroll | `switch-to-buffer` for the cover, then `quit-window` | Cover a buffer, then restore it. | Restore that window's cursor and scroll state, adjusted for intervening edits. Do not use another window's cursor. |
| V02 — Independent duplicate views | `split-window-right`, `other-window`, move point; then `C-x l r` | Two windows show the same buffer at different locations. Rearrange or restore them. | Keep both locations associated with their respective window identities. |
| V03 — Manual scrolling | Scroll manually; **proposed:** `window-hide`, `hidden-window-show!` | Manually scroll a window, hide it, and reveal it. | Preserve its manual/follow state and scroll position where supported. |
| V04 — Content changes while hidden | **Harness:** edit an invisible window’s buffer; **Proposed:** `hidden-window-show!` | Edit a buffer while its window is invisible. | Preserve document edits and restore an adjusted valid view. Do not restore an old copy of the text. |
| V05 — Passive display focus | **API:** `(display-buffer BUFFER)` | Display a buffer without selecting it. | Preserve the selected logical window and its editing position. |
| V06 — Background buffer creation | **API:** `with-current-buffer` and `visit-quietly`; no display command | Create or update buffers headlessly. | Do not create visible panes or change any visible stack. |
| V07 — Redraw and modeline update | **Harness:** render refresh and modeline update events | Trigger rendering, status updates, or mode-line refreshes. | Do not add return layers, change owners, or reveal hidden windows. |
| V08 — Failed or cancelled action | `find-file` / `switch-to-buffer`, then `keyboard-quit` (`C-g`) | Cancel a picker or fail an open before display succeeds. | Preserve view state, history, registry, layout target, and selection. |

## 11. Entry-point consistency

Run the relevant opening, consolidation, and quitting scenarios through each path.
A specialized application must not bypass the contract by calling a lower-level setter.

| Case | Command or trigger | Entry point | Required result |
| --- | --- | --- | --- |
| E01 | `mode-consolidate` and `dired-quit` through `KeyDispatch.handle_key` | Keyboard command dispatch, including mode-consolidate and Dired quit. | Same ownership, stack, and degradation behavior as direct command invocation. |
| E02 | `ibuffer`, then `RET` on a chat row | Buffer browser selection. | Selecting a chat uses its group-owned mode window; merely opening the browser does not split chats across panes. |
| E03 | `chat-list`, `chat-list-visit`; **harness:** primary-chat opening path | Chat-list and primary-chat commands. | Reuse the same mode destination within the group. |
| E04 | `find-file` (`C-x C-f`), `dired`, `dired-open` | File visit and directory navigation. | Respect the destination window and group scope; preserve source and destination histories separately. |
| E05 | Click a buffer link or an application row | Buffer links and clickable application rows. | Apply the same validation as keyboard opens. |
| E06 | **API:** `display-buffer` with and without `inhibit-same-window` | Passive display requests and explicit other-window requests. | Honor focus constraints without violating group ownership or the default routing of new buffers. |
| E07 | **Harness:** agent/tool call to `switch-to-buffer!` or `display-buffer` | Agent and tool display calls. | No privileged bypass around window routing or group boundaries. |
| E08 | **API:** `set-mode!`; application refresh commands such as `notmuch-refresh` | Mode setup and application refresh. | Rebuilding keys, rendering, or runtime state does not create extra mode windows. |
| E09 | **API:** `tile-windows!`; **proposed:** logical-window-ID layout API | Explicit layout APIs. | Supplying buffers or foreign IDs to a compatibility API cannot reopen internal stack entries or import another group's windows. |
| E10 | `group-switch`, `winner-undo`, chooser `C-g`; **harness:** desktop restore | Group restore, layout undo, preview cancellation, and desktop restore. | All validate current ownership and preserve logical stack identity. |

## 12. Layout keyboard shortcuts

Run these cases through keyboard dispatch, starting with `C-x l`. See
[the keymap reference](KEYMAPS.md#layout-selection) for the binding list.
`C-x l` opens the `window-layout` chooser. In the chooser, each key below
picks its layout at once. An arrow moves the chooser's highlight.
`layout-forward` and `layout-backward` have no stock key.

| Key after `C-x l` | Command | Meaning |
| --- | --- | --- |
| `1` | `window-layout-single` | One window |
| `2` | `window-layout-two-pane` | Two panes, 2/3 + 1/3 |
| `=` | `window-layout-halves` | Two equal panes |
| `c` | `window-layout-columns` | Three columns |
| `r` | `window-layout-rows` | Two rows |
| `f` | `window-layout-free` | Free layout |

No key chooses the main pane's side at this time. K02 and L08 are proposed.

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| K01 — Layout prefix | `C-x l 1`, `C-x l 2`, `C-x l =`, `C-x l c`, `C-x l r` | Press C-x l, then each of 1, 2, =, c, and r in separate runs. | Select single, two-pane, halves, columns, and rows respectively. Each uses the window-preservation and group-boundary rules above. |
| K01b — Scroll the layout | `M-x layout-forward`, `M-x layout-backward` | Run each command. | Move the panes one window along the frame's window ring. The ring is cyclic, so neither direction reaches an end. The window that leaves becomes hidden; it keeps its buffer, history, and point. |
| K02 — Main direction | **Proposed:** `C-x l` plus left, right, up, down | Press C-x l followed by left, right, up, or down. | Place the main pane on the named side. Preserve logical window stacks while changing pane geometry. |
| K03 — Chooser | `C-x l`, then `RET` / `C-g` | Press C-x l, preview layouts, then accept or cancel. | Open the chooser and follow L15–L17. Cancellation restores the original arrangement. |
| K04 — Free layout | `window-layout-free` (`C-x l f`) | Press C-x l f. | Select free layout. Mode routing, consolidation, and group ownership still apply. |
| K05 — Cancel prefix | `C-x l C-g` | Press C-x l and cancel before selecting a layout. | Leave windows, stacks, focus, geometry, and the layout target unchanged. |
| K06 — After consolidation | `mode-consolidate`, then every `C-x l` layout selection | Consolidate chats, then exercise every layout shortcut. | Hidden chats never become extra windows. Displaced non-mode windows remain invisible. No shortcut imports another group's content. |

## 13. Regression journeys from this conversation

### R01 — Two chats reappear after columns

1. Use `switch-to-buffer` to open several chats belonging to one group.
2. Run `mode-consolidate` in the selected window.
3. Run `ibuffer` in another window.
4. Press `C-x l c`; repeat through the chooser with `C-x l`.
5. Inspect every visible and invisible window, not just the screen.

**Expected:** one group-owned chat destination remains. Its hidden chats stay in
its stack. The browser stays separate. Spare columns do not open another chat.

### R02 — Dired reveals a transferred chat

1. Arrange a chat window beside a Dired window that has another chat underneath it.
2. Run `mode-consolidate` while selected in the chat window.
3. Use `other-window` to select Dired, then press `q` (`dired-quit`).
4. Repeat with several Dired predecessors and with an obsolete quit record.

**Expected:** no transferred chat appears in Dired's window. Remaining Dired
history is consumed; when exhausted, that window closes and the layout shrinks.

### R03 — Non-mode buffers become visible during consolidation

1. Put documents and listings beneath chats in the selected window.
2. Record the selected window identity, pane, and focus.
3. Run `mode-consolidate`.

**Expected:** the selected chat window stays visible and selected in its pane.
The non-chat stack moves to an invisible window. No new visible window is created.
Only exhausted source windows may disappear.

### R04 — Another group supplies a spare window

1. Give group B a visible chat window, an invisible chat window, and very recent chat buffers.
2. Run `group-switch` to A, which has fewer windows than its layout target.
3. Run `switch-to-buffer`, `C-x l c`, `mode-consolidate`, and `dired-quit`.
4. Run `group-switch` away and back to restore A's arrangement.

**Expected:** every action stays within A. No B window or buffer is borrowed,
even briefly. Insufficient eligible windows produce a smaller layout.

### R05 — History comes back through restoration

1. Save a group arrangement containing several chat windows.
2. Run `mode-consolidate` to separate non-chat content into an invisible window.
3. Run `group-switch` away and back. Use the disposable desktop save/restore harness.
4. Press `C-x l c`, then run `quit-window` in the non-chat windows.

**Expected:** the consolidated destination survives every transition. No saved
layout, hidden record, or quit route reintroduces chats into another window.

### R06 — Exiting chat-list garbles the underlying windows

1. Arrange two windows with separate buffer histories and cursor positions.
2. Select the second window. Record geometry, layout target, group, and pin.
3. Run `chat-list`, then `chat-list-quit` through keyboard dispatch.
4. Repeat with ungrouped windows and two views of the same buffer.
5. Repeat after opening chat-list twice, and after invoking quit twice.
6. Open chat-list in two frames, then quit each independently.

**Expected:** each frame restores its own invoking arrangement, selection, histories,
points, quit records, and cycle-mode settings. Re-entry preserves the invoking window's predecessor.
A second quit does nothing. Exit never reconstructs the layout from one remembered buffer.

Chat-list covers only the invoking window. Its read-only peek floats above the workspace and never takes focus. Ordinary window history owns return; there is no frame-wide snapshot to replay. The return tests exercise grouped and ungrouped windows, duplicate displays, re-entry, and two frames.

### R07 — Floating peek cards

| Case | Commands | Expected result |
|---|---|---|
| R07a — Navigate | `n` / `p` in `ibuffer` or `ichat` | After a short pause, show a raised, inset Preview card linked to the selected row. |
| R07b — Focus | `other-window`, focus arrows, or click the card body | The card never takes focus. Its body has no interactive controls. |
| R07c — Dismiss | `q` or the card's q button | Close only the card. Keep the source list, its selection, and focus. Do not reopen on the same row. |
| R07d — Exit | `q` again | Reveal the source window's predecessor normally. |
| R07e — Select | `RET` in the source list | Close the card and open the original buffer through the selection rules. |
| R07f — Isolated view | Preview a buffer already visible elsewhere | Original text, point, mode, group and window classes remain untouched. |
| R07g — Delayed callback | Move a row and immediately dismiss/leave | Cancel the queued peek. It cannot recreate the dismissed card. |
| R07h — Geometry | Resize or scroll at different editor zoom levels | Keep the card inset and its connector attached to the visible source row and card edge. |
| R07i — Picker exit | `C-g` in `C-x b` | Remove both picker and card; restore the invoking buffer. |

## 14. Applications inside a group — proposed contract

**Superseded for chat-list:** ichat/chat-list is now an ordinary group-owned listing, as specified in R07. The home-workspace proposal below remains a design option for other applications, such as notmuch.


An application provides tools and an optional workspace layout. An application
instance belongs to one group. Its buffers inherit that instance's group.

Use the same launch convention for every application:

| Invocation | Destination | Layout |
| --- | --- | --- |
| `M-x notmuch` / `M-x chat-list` | The application's own group | Restore that application's workspace. |
| `C-u M-x notmuch` / `C-u M-x chat-list` | The current group | Open its local instance through normal window routing. Preserve the group's layout target. |

The prefix applies to launch, not every later action. The instance remembers its
group. Search results, previews, and child views inherit it, including asynchronous results.
Repeating the prefixed launch in Recruiting reuses Recruiting's instance.
Launching it in another group creates or reuses that group's separate instance.

The home instance remains intact. Do not move its singleton buffers into Recruiting.
Instances may share a mail database or chat index. They keep separate selection,
filters, buffer identities, and window state. Store instance identity with each buffer.
Callbacks must capture that identity, not consult whichever frame is active later.

A local chat-list defaults to the current group's chats. An explicit all-groups
filter may show foreign rows as references. It must not display foreign chat buffers
inside the host group. A preview uses an instance-owned read-only presentation.
Opening a foreign row explicitly navigates to its owning group.

Quitting unwinds the local instance's own windows. It does not collapse Recruiting's
layout or select a global recent buffer. Opening an app is not permission to replace
the host layout. A separate, explicit layout action can apply the app's arrangement.

**Implementation status:** these prefix semantics are proposed. `M-x notmuch` opens
its singleton view buffers in the current group. `M-x mail` enters the `mail` group scene. Skipping the group
switch alone cannot implement local instances safely.

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| A01 — Home launch | `M-x notmuch`; repeat with `M-x chat-list` | Launch normally from Recruiting. | Save Recruiting's arrangement and enter the app's home group. |
| A02 — Local launch | **Proposed:** `C-u M-x notmuch` | Launch from Recruiting. | Create a Recruiting-owned instance. Preserve the host group and layout target. |
| A03 — Local chat list | **Proposed:** `C-u M-x chat-list` | Launch from Recruiting. | Show Recruiting's chats in a Recruiting-owned list buffer. |
| A04 — Repeated launch | **Proposed:** repeat `C-u M-x notmuch` or `C-u M-x chat-list` | Launch the same app twice in Recruiting. | Reuse its instance, buffers, and destination windows. |
| A05 — Two host groups | **Proposed:** prefixed launch after `group-switch` | Launch the app in Recruiting and Design. | Keep separate instance state and single ownership for every buffer. |
| A06 — Home stays home | Normal launch, then **proposed** prefixed launch elsewhere | Record the home instance before opening a local instance. | Preserve all home buffers, stacks, filters, and selection. |
| A07 — Child view | **Proposed local instance:** `notmuch-hello-open`, then `notmuch-open-thread` | Open a mailbox and message from Recruiting's mail instance. | Every child belongs to Recruiting without requiring another prefix. |
| A08 — Delayed result | **Harness:** delay a local search, then `group-switch` | Finish the search after leaving Recruiting. | Update its captured instance. Do not display into the newly selected group. |
| A09 — Host layout | **Proposed:** prefixed launch after `C-x l 2` | Launch with both host panes occupied. | Follow normal placement policy. Do not apply the app's home scene or discard host stacks. |
| A10 — Apply app layout | **Proposed:** explicit app-layout action; command not yet defined | Request the app's arrangement inside Recruiting. | Arrange eligible Recruiting windows only. Preserve displaced windows invisibly. |
| A11 — Local quit | **Proposed local instance:** `notmuch-quit` / `chat-list-quit` | Quit after using the embedded app. | Unwind that instance's windows. Do not collapse unrelated panes or borrow replacement buffers. |
| A12 — Foreign chat reference | **Proposed local chat-list:** all-groups filter, then `chat-list-visit` | Select a chat owned by Design. | Explicitly navigate to Design. Keep Recruiting's instance and arrangement intact. |
| A13 — Foreign preview | **Proposed local chat-list:** select a foreign row | Preview without visiting its group. | Render a local read-only presentation. Do not attach the foreign chat buffer to a Recruiting window. |
| A14 — Consolidation stays scoped | **Proposed local instance:** `mode-consolidate` | Consolidate an app mode inside Recruiting. | Touch Recruiting's eligible buffers only. Leave home and other groups' instances intact. |
| A15 — Restore instances | **Harness:** desktop save and restore | Save home and two local instances. | Restore each instance's owner, view state, and child-buffer relationships. |
| A16 — Prefix without a group | **Proposed:** `C-u M-x notmuch` in an ungrouped frame | Launch without a current group. | Open an explicitly ungrouped instance. Do not silently enter the app's home group. |
| A17 — Shared backend | **Harness:** refresh two local instances after a backend change | Both instances read the same mail database or chat index. | Refresh data while retaining independent filters, selection, and ownership. |
| A18 — Quit last app window | **Proposed local instance:** `quit-window` | Exhaust the instance's last window while other host windows survive. | Close that window and degrade the host layout. Do not restore the app's home scene. |

## 15. The same file in different groups — proposed extension

Use separate buffer identities for separate groups visiting the same file.
Within one group, repeated visits reuse its buffer. The canonical path identifies
the file; it does not identify the group-owned buffer.

Keep this extension separate from membership enforcement, which already exists.
Two buffers writing one file need revision checks. A later save must not silently
overwrite changes saved by the other buffer. The following cases specify that requirement;
they do not claim the current file implementation supports it.

| Case | Command or trigger | Setup and action | Required result |
| --- | --- | --- | --- |
| F01 — Same file, different group | **Proposed behavior:** `find-file` (`C-x C-f`) after `group-switch` | Open one path in A and B. | Create separate buffers, each with one owner. Do not move A's buffer. |
| F02 — Revisit within group | **Proposed behavior:** repeat `find-file` in A | Visit A's path again with unsaved changes. | Reuse A's buffer and preserve its edits and view. |
| F03 — Independent views | **Proposed behavior:** `group-switch` between A and B | Change cursor and scroll in each file buffer. | Preserve each buffer's group, windows, and view state. |
| F04 — Concurrent saves | **Proposed behavior:** `save-buffer` (`C-x C-s`) in A, then B | Both buffers have edits based on the same earlier revision. | Detect B's stale base and require conflict resolution before overwriting A's saved changes. |
| F05 — File rename | **Proposed behavior:** `dired-rename` | Rename a file visited by two groups. | Update or explicitly invalidate both file associations without merging buffers or changing owners. |
| F06 — Restart | **Harness:** save and restore both proposed file buffers | Restart with separate group buffers for the same path. | Restore both identities, owners, unsaved state, and file revision metadata. |

## Coverage and completion

Single ownership is already enforced by `buffer-add-group!`, `buffer-move-to-group!`,
and the chat ownership functions in [groups.scm](../scheme/packages/groups.scm).
[groups-test.scm](../scheme/packages/groups-test.scm) tests immediate replacement
of work-buffer ownership and normalization of legacy multiple memberships.
These checks do not prove the window registry or proposed application instances.

The existing suites cover parts of display routing, group cycling, consolidation,
Dired quitting, layout geometry, frame state, and history. They do not collectively
prove this entire contract. Tests that expect spare panes to be filled from hidden
buffers are incompatible with this contract.

For each implemented case, record its automated test or reproducible inspection
and its result. A release claim requires the relevant behavior tests to pass through
the actual command path. A source-text assertion or a screenshot alone is insufficient.

The last-window behavior in Q09 is the current explicit boundary: preserve it and
report the condition. It does not authorize a scratch replacement, foreign fallback,
or invisible-window reveal.

### Dismissal boundary regression coverage

`apps/compos_core/test/compos/dismiss_test.exs` exercises foreign-history rejection
through key dispatch for `dismiss-buffer`, `quit-window`, and `dired-quit`.
It covers G09 saved histories and return records, G07 first-entry history isolation,
Q05 exhausted child panes, and Q09 last-window preservation. An ungrouped
application listing is not a global utility cover. Only explicit temporary covers
and Help receive that exception. These cases do not certify the full window registry.

## Explicit picker placement — current rule

`C-x b` chooses the physical pane. Mode affinity moves the whole logical
window there, preserving its stack. The displaced window takes the vacated
pane. A hidden stack exchanges with the selected pane without a split.
Foreign selections enter their owning group first; windows never cross groups.
This supersedes older cases describing `C-x b` as following a mode window.

| Case | Command | Expected result |
| --- | --- | --- |
| E01 — Visible mode window | `C-x b`, select another chat, `RET` | Move the chat window into the invoking pane and show the choice. Preserve its stack. |
| E02 — Hidden stack | `C-x b`, select a hidden mode buffer, `RET` | Exchange its stack with the chosen pane's stack; preserve pane geometry. |
| E03 — No attraction | `C-x b`, select a mode with no window | Show the buffer in the invoking pane. |
| E04 — Same pane | `C-x b`, choose another buffer of this mode | Keep the window in place. |
| E05 — Foreign group | `C-x b`, choose a foreign buffer | Enter its group; only move windows belonging to that group. |
| E06 — Return | `ibuffer`, `RET` on Amazon detail, `q` | Return to the same-group ibuffer, even after moving the mode window. |
| E07 — Open elsewhere | `C-x o` or `Cmd-RET` while peeking | Dismiss the copy and open the original in another work window; split if needed. |
| E08 — Scroll | Wheel or trackpad over the preview | Each new preview starts at the bottom and scrolls independently, without focus. |
| E09 — Cross headings | `n` / `p` across group sections | Keep the pane-sized card and normal font size; no ibuffer animation. |
| E10 — Rich mode | `n` / `p` onto chats and block views | Preserve source mode and rich presentation without copying chat runtime identity. |

Normal mode-driven opens continue to use mode attraction.

### Preview toggle

In ibuffer, `p` toggles automatic previews for that listing. Turning previews
off dismisses the card and cancels pending previews. Arrow navigation does not
reopen it until previews are enabled again. Turning previews on immediately
previews the selected buffer. With previews enabled, `q` dismisses the current
card, and the next arrow movement may reopen it, including at a list boundary.

| Case | Commands | Expected result |
| --- | --- | --- |
| E11 — Toggle off | `p`, then `<up>` / `<down>` | Navigate without creating a preview. |
| E12 — Toggle on | `p` again | Immediately preview the selected buffer. |
| E13 — Resume after dismissal | `q`, then `<up>` | Show the selected buffer's preview again; keep focus in ibuffer. |
| E14 — Kill previewed entry | `k` in ibuffer while its preview is open | Kill the original named by the row, refresh ibuffer, and remove the separate preview copy and its popup. Keep focus in ibuffer. |
| E15 — Decline kill | `k` on a modified file, then answer no | Keep the original, its row, and its preview. |

### Highlight drives preview

Every list mode with a `preview` callback previews a newly highlighted entry
after refresh or filtering, as it does after arrow navigation. This is shared
list behavior: individual kill/archive commands do not choose the next preview.
Unchanged selection does not repeat the callback; background list refreshes
do not change the active preview.

| Case | Commands | Expected result |
| --- | --- | --- |
| E16 — Kill and follow | `k` in ibuffer with another row remaining | Remove the killed original and its copy, refresh the list, and preview the newly highlighted buffer. |
| E17 — Refresh selection | `g` after the selected entry disappears from the source | Run the list mode's preview callback for the replacement selection. |
| E18 — Background refresh | Refresh a list while another buffer has focus | Restore that list's point without opening its preview. |

### Preview scope

`C-x C-b` uses floating preview cards (toggle with `p`). `C-x b` previews the highlighted buffer directly in the invoking pane, without a floating card or history entries. `C-g` restores the original buffer, point, and history. Before `RET` applies the normal chosen-pane placement rule, it restores the underlying arrangement so the preview cannot masquerade as the preferred mode window. Opening the minibuffer picker dismisses any existing floating preview.
