# Semantic components by use case

Elements identify concepts; attributes contain domain values, never values guessed
from rendered text. CSS and the existing editor interaction layer own presentation.
A c-text or c-group does not count as a domain component.

| Use case | Components | Data contract |
| --- | --- | --- |
| Dired | directory, file, filename, size, modified, permissions, vcs-status, icon, size-bar | directory path; entry path/name/kind/mark; bytes and mtime; displayed fields retain exact column layout |
| Chat | c-transcript, c-user, c-agent, c-toolcall, c-arguments, c-result, c-info, c-summary, c-input, c-question, c-answers, c-permission, c-plan | author, queued state, call identity/name/status, input/cursor, answer and permission actions |
| Mail | mailboxes, mailbox, mail-threads, mail-thread, mail-subject, mail-participants, mail-date, mail-tags, mail-tag, mail-message, mail-from, mail-to, mail-body, mail-attachments, mail-attachment | query/source/profile; thread/message identity; unread and bulk-mark state; attachment part/type |
| Morg agenda | morg-agenda, agenda-day, agenda-entry, agenda-title, agenda-time, agenda-deadline, agenda-scheduled, agenda-task-state, agenda-tags, agenda-source | task title/state, planning kind, time, source file and heading location |
| Buffer list | buffers, buffer, buffer-name, buffer-mode, buffer-size, buffer-state | stable buffer identity, mode, size and state; section headings are headings |
| Chat list | chat-list, chat-entry, chat-name, chat-state, chat-tokens, buffer-activity | stable chat identity, runtime state, token count and activity; reuse compact column layout |
| Imenu | symbol-list, symbol-entry, symbol-name, symbol-kind, symbol-location | original symbol name, outline kind, source buffer and line; selection remains the minibuffer's |
| Preview | c-preview, native iframe | source buffer and rendering kind; iframe keeps its sandbox, content and scroll hook |

Dired's narrow layouts may omit visible fields. The file still carries
full name/path, bytes, mtime and permissions. These are raw metadata, not parsed
copies of truncated column strings. The same layout pass supplies field byte
boundaries, so semantic wrappers do not introduce a second layout implementation.

Native controls (button, details, summary, iframe) keep their browser behavior.
Semantic elements wrap or label them where appropriate. Generic text wrappers
remain permissible inside a domain value for face or cursor spans; they are not
substitutes for the value's semantic element.

Ibuffer and ichat entries render their fields as direct children. Uniform face
classes live on the field itself; mixed cursor/face runs alone need inner spans.
The mode supplies CSS Grid rules; field column metadata preserves its compact
column layout without padding text nodes.
The entry itself supplies the frontend row class, source offset and line number;
CSS draws the gutter, and mouse position handling accepts the entry as content.
Agents use element names and domain attributes, never those frontend classes.

Direct column records opt in with `layout: "columns"` in the Scheme descriptor.
The renderer does not branch on domain tag names. Dired, Ibuffer and ichat
supply their own CSS Grid rules; field placement derives from the mode's
column layout. These read-only rows retain source positions for navigation.
