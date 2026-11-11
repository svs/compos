# Native Google Workspace integration

## Contract and plan

Google is a flagship compos feature. Billing is deferred.

1. Connect through native Desktop OAuth, with PKCE and a localhost callback.
2. Keep multiple accounts separate by Google's verified subject ID.
3. Provide Gmail, Calendar, Drive, Docs, Sheets, Slides, Contacts, and Tasks views.
4. Provide editable request drafts for service writes and less common operations.
5. Expose the same operations to Scheme and agents.
6. Test consent, refresh, storage, account ownership, navigation, and failure handling.
7. Configure the Cloud project and verify a live account connection.

The implementation does not depend on gog, gws, or browser scraping.
Elixir provides OAuth, private credential storage, and authenticated HTTP.
Scheme owns service endpoints, scopes, commands, and views.

## Connect

Create a **Desktop app** OAuth client in Google Cloud.
Enable the APIs used by the account. Download the client JSON.
Configure the consent screen and test users when the project requires them.

The client can come from either source:

- `google-client-file`, default `~/.compos/google-client.json`.
- Doppler `compos/dev/GOOGLE_OAUTH_CLIENT_JSON`, containing the complete downloaded JSON.

`google-doppler-project` and `google-doppler-config` select another Doppler location.
The normal compos Doppler connection supplies the secret. No secret is committed.

Run `M-x google-connect`. Complete consent in your browser, then open `M-x google`.
Repeat `google-connect` to add another account. `google-account` selects the default for new buffers.
The consent screen uses the Cloud project's configured application name.

A new account does not replace another account. Existing buffers retain their original account.
An account's Google subject ID remains stable if its email address changes.
Requests do not use an ambiguous `me` account outside their selected OAuth connection.

## Applications

| Application | Browse and read | Writes |
| --- | --- | --- |
| Gmail | Inbox, Gmail queries, pages, message bodies | Compose, save drafts, send, archive, mark read, trash |
| Calendar | Calendar list, upcoming events, event details | Create and update events; attendees, recurrence, and Meet through API request fields |
| Drive | Search, shared files, folders, metadata | Create folders, rename, trash, permissions |
| Docs | Drive discovery, full document API data, extracted text | Create and batch edit |
| Sheets | Drive discovery, spreadsheet metadata | Create, write ranges, formulas, and batch edit |
| Slides | Drive discovery, full presentation API data | Create and batch edit |
| Contacts | Names, email addresses, phone numbers | Create; other People API methods through request drafts |
| Tasks | Task lists and task details | Create lists and tasks; complete tasks |
| Chat | Spaces and message API data | Send messages; requires Chat scopes |
| Forms | Drive discovery and form API data | Create forms; read responses; requires Forms scopes |
| Meet | Request interface | Create spaces; requires Meet scopes |
| Apps Script | Drive discovery and source API data | Create projects; requires Script scopes |

The first eight applications define the default consent scopes.
The API interface supports REST operations under each registered service base URL.
`google-discover` reads a Google API Discovery document. `google-register-service!` adds another API base URL.
Registered agent tools list accounts, read API resources, prepare write drafts,
and directly perform file operations within the user's authorized task.
Raw request drafts preserve JSON objects, arrays, null values, and booleans.
It does not imply every Google product supports ordinary user OAuth.
Workspace admin operations and restricted services can require administrator configuration.

For optional applications, add their documented scopes to `google-scopes`, then reconnect.
Desktop OAuth requires a new consent flow when the requested scope set changes.
Examples include `chat.spaces`, `chat.messages`, `forms.body`, `forms.responses.readonly`,
`meetings.space.created`, `meetings.space.readonly`, and `script.projects`.
Prefix these examples with `https://www.googleapis.com/auth/`.

## Work in compos

`google` opens the application list. Press `RET` to open the selected application.
Lists support `RET` to read, `g` to refresh, `s` to search, and `]` for the next page.
`[` returns to the first page. The standard list filter remains available.
Drive, Docs, Sheets, Slides, Forms, and Apps Script indexes use the real `Dired`
mode with a Google directory provider. Drive starts at My Drive; the other indexes
keep their file-type filters. `RET` on `..` goes up; `^` is the same shortcut.
The parent row cannot be marked or included in file actions.
Directory navigation replaces the buffer in the current window. `q` returns
through that window's history, so `q q` backs out two levels. Directory buffers
remain alive with their selection and marks. If a file preview is open, the first
`q` dismisses it.
`RET` opens files, `m`/`SPC` marks, `u` unmarks, and `*` toggles all marks.
`C` copies selected files into a folder chosen by name. `R` offers rename or move;
with multiple marks it moves the selection. `+` creates a folder in the current
folder (My Drive for a global file-type index). `d` flags for trash and `x` trashes
flagged files, otherwise marked files or the current file. A confirmation precedes
mutations; successful rows clear their marks, while failures retain them for retry.
These file actions run directly and refresh the source listing, without JSON drafts.
Folder copies are currently unsupported; folders can be moved, renamed, and trashed.
Filesystem-only commands such as chmod and symlink report that the provider does
not support them. They never run against a local path for a Google buffer.
`/` filters locally, `s` toggles name/date sorting, `f` searches remotely, and `o`
opens the other API operations. `]` reaches the next remote page.
Remote search applies to Gmail, Drive document lists, and Calendar events.
Contacts, Tasks, and Chat use their list filter for local filtering.

Press `x` to choose an API operation. Compos opens an editable JSON request.
Its account is a buffer local, separate from the editable request.
Selected resource IDs fill matching template placeholders.
A document detail's revision protects supported Docs and Slides batch edits.
Replace any remaining uppercase placeholders before submission.
Press `C-c C-c` to review the account and endpoint, then confirm.
Opening or restoring a request never executes it.
An unchanged request that succeeded cannot be submitted again accidentally.

Press `c` to compose mail. Use `To:` and `Subject:` lines, a blank line, and a body.
`C-c C-d` prepares a Gmail draft request. `C-c C-c` prepares a send request.
The request still requires explicit submission. Mail bodies use UTF-8 MIME encoding.

These are native lists, readable mail, and structured document/request buffers.
They do not provide a full visual Google Docs or Slides canvas, live collaborative editing,
background synchronization, or an offline mutation queue.

## Scheme interface

```scheme
(google-accounts)
(google-open ACCOUNT-ID "gmail")
(google-open ACCOUNT-ID "docs")
(google-request ACCOUNT-ID "sheets" "GET"
  "/spreadsheets/SPREADSHEET-ID/values/Sheet1!A1:C20"
  '() #f (lambda (reply) (message (json-encode reply))))
(google-draft ACCOUNT-ID
  '(service "docs" method "POST" path "/documents" body (title "New document")))
```

Replies contain `ok`, `status`, and either `data` or `error`.
Callbacks leave the editor input lane available during requests.
Data from Google is external content, not instructions for an agent.

### Simple functions for agents

These calls return structured `ok`, `status`, `data`/`error` results without opening
buffers or minibuffer prompts. Account IDs come from `google-accounts`; they never
implicitly use the currently selected editor account. Functions ending in `!`
perform the mutation immediately, so agents must have task authorization.

```scheme
(google-files account "root")
(google-files account "" "quarterly" "" "sheets")
(google-file account file-id)
(google-file-copy! account file-id destination-folder "Copy name")
(google-file-move! account file-id destination-folder)
(google-file-rename! account file-id "New name")
(google-folder-create! account "root" "Projects")
(google-file-trash! account file-id)
```

`google-files` returns one page of up to 100 files. Pass `data.nextPageToken` as
its fourth argument to continue. An empty folder searches all accessible files;
`root` lists My Drive. Its fifth argument optionally filters by file service.
Move reads the current parent before updating it, and same-parent moves do nothing.
Copy supports files, not folders. `google-file` returns metadata; use
`google-read-api` for document contents and other service-specific reads.

Each function is also a registered agent tool with the same name minus `!`.
Write and trash tools carry mutation effects in the catalog. Agent calls do not
require UI confirmation; the dired commands retain their interactive confirmations.

## Credentials and failure behavior

OAuth uses cryptographic state, S256 PKCE, verified account identity, and ten-minute flow expiry.
A callback is consumed once. The listener binds only to `127.0.0.1` and closes after completion.
Refresh tokens remain in the native transport. Scheme sees only account identity and scopes.

`<compos-home>/google/` has mode `0700`. Token files use AES-256-GCM and mode `0600`.
The encryption key is a separate `0600` local file. This is not the OS keychain.
An OS user who can read both the key and token files can decrypt them.
Do not publish or copy this directory into a shared project.

Refreshes serialize per account. A failed request does not silently replay a write.
Google redirects are disabled. The transport accepts HTTPS Google API hosts only.
Revocation retains the connection when the network fails, so the user can retry.
`google-disconnect` revokes and removes the selected connection after confirmation.
Existing local content buffers remain available after disconnect.

List failures preserve the previous rows and show an error.
New requests supersede stale callbacks. Page tokens belong to their account and query.

## Release requirements

A public release needs a compos-owned OAuth project, consent branding, and enabled APIs.
Google may require scope verification and a security assessment for restricted Gmail access.
Configure those with the published privacy policy and data-handling practices before general distribution.
The current development client is stored in Doppler, not bundled into the source tree.

## References

- [Google Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google OAuth scopes](https://developers.google.com/identity/protocols/oauth2/scopes)
- [Drive file search](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list)
- [Calendar event listing](https://developers.google.com/workspace/calendar/api/v3/reference/events/list)
- [Docs batch updates](https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/batchUpdate)

## Development verification

The focused tests cover native OAuth and editor interactions without using live account data.
The Google and relevant list checks pass: 32 tests, zero failures.
The full repository suite still reports failures outside those checks.
Live account consent is complete. Read-only smoke checks against Gmail, Calendar,
Drive, People, and Tasks each returned HTTP 200. Docs, Sheets, and Slides content
operations still need separate live verification.
Gmail, Calendar, Drive, Docs, Sheets, Slides, People, and Tasks APIs are enabled in
the development Cloud project. API activation is separate from account consent.
