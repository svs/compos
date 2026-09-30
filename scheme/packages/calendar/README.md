# Calendar

One calendar surface over every account the operating system already knows about. The store is a text file. Scheme owns the verbs, the parse and the views. There is no Elixir module, no compiled binary, no OAuth client, no token, and on macOS no CalDAV.

This is not a Google Calendar MCP. One MCP server per provider is a tool zoo: two accounts on two providers gives four servers, four vocabularies and no merged view. An MCP server is also a chat door only, so it cannot draw a week, hold an offline edit or merge two calendars. Instead we build one verb surface, wrap it once with define-tool!, and the compos MCP server serves it outward for free.

## What the probes settled

Every row below was measured on this machine on 2026-09-08, not assumed.

| question | answer | evidence |
| --- | --- | --- |
| Does macOS ship a calendar CLI? | No, cal is a month grid | Calendar.app is scriptable but ships no command |
| Can we reach EventKit without a compiler? | Yes, osascript -l JavaScript and the ObjC bridge | probe.js returns real calendar titles |
| Does the compos daemon get calendar access? | No, and it never can | launchctl managername is Background, and TCC cannot prompt a Background process |
| Does a LaunchAgent get access? | Yes | same script, same second: Aqua returned 10 calendars, Background returned 0 |
| Does the grant follow the binary into the daemon? | No | TCC records kTCCServiceCalendar for /bin/zsh as allowed, and the daemon still reads 0 |
| Can we write? | Yes, to a real Google account | created, read back and deleted an event in the Google account |
| Do we need an RRule engine? | No | EventKit returns expanded occurrences, not rules |
| Does Google CalDAV take an app password? | No | PROPFIND returns 401 with no WWW-Authenticate header at all, Bearer only |
| Does iCloud CalDAV take an app password? | Yes | 401 with WWW-Authenticate: Basic realm MMCalDav |

The consequence of rows three to six is the whole design: macOS already holds the accounts, the OAuth, the token refresh and the incremental sync for all nine of your stores, and it will hand them over in both directions, but only to a process in the Aqua session.

## The shape

| piece | where | what it does |
| --- | --- | --- |
| the config | ~/.compos/calendar.scm | which sources exist, and which provider each one uses |
| the provider seam | calendar.scm | one contract; macos is one implementation and CalDAV is another |
| the agent | a LaunchAgent, Aqua session | the only thing that touches EventKit; reads calendars, drains the outbox |
| the payload | agent/*.js, run by osascript -l JavaScript | EventKit calls, no compiler and no binary |
| the spool | ~/.compos/calendar/ | request and result files; the door between the two sessions |
| the store | one text file | the truth compos reads and renders; survives with no agent running |
| the parse | Scheme, tree-sitter markdown | (ts-langs) already loads markdown and markdown-inline |
| the views | morg-agenda-mode, plus a week grid | day cards, n and p, TAB fold, RET open, [ and ] by week |

Elixir appears nowhere. The editor already has shell exec and an async lane, so nothing in this list needs a new module, a supervisor or a database.

## Providers

A provider is one way to reach calendars. macos is one provider, not the design. Above the seam nothing knows which provider answered.

| provider | reaches | reads | writes | occurrences |
| --- | --- | --- | --- | --- |
| macos | every account Calendar.app holds: iCloud, Google, Exchange, subscribed, Todoist | yes, through the Aqua agent | yes | expanded by EventKit |
| macos-db | the same accounts, with no grant at all | yes | no | rules only |
| caldav | iCloud, Fastmail, Nextcloud, and Google with a bearer token | yes | yes | rules only |
| ics | any subscription URL | yes | no | rules only |
| vdir | a vdirsyncer directory, which is what Linux actually runs | yes | yes | rules only |
| local | a calendar compos owns, kept in the text file | yes | yes | none |
| google | one Google account over REST, through the editor's own OAuth (google-connect) | yes | yes, and update | expanded by Google |
| gog | one Google account through the gog CLI and its keychain token | yes | yes, and update | expanded by Google |

The contract:

    (calendar-provider-define! 'NAME
      'calendars    (lambda (src) ...)          every calendar the source reaches
      'events       (lambda (src from to) ...)  occurrences in a window
      'put!         (lambda (src event) ...)    create or update, returns a uid
      'delete!      (lambda (src uid) ...)
      'update!      (lambda (src id expect changes) ...)   only with update
      'capabilities '(read write update expanded))

The capability that matters most is `expanded`. macos returns occurrences, so nothing expands recurrence. Every other provider returns rules, so the RRule work comes back with the first non-macOS provider and not one day before. It is bought when it is needed.

A provider that cannot write omits `put!` and `delete!` and leaves `write` out of its capabilities. A verb asks the capability rather than calling and catching.

`macos` and `macos-db` are registered today with the capabilities the probes settled. Their functions arrive with P2, so a verb that asks `(calendar-provider-can? 'macos-db 'write)` already gets the right answer, which is no.

## Configuration

Sources live in a file, not in customize. `~/.compos/calendar.scm` follows the convention already used by `custom.scm`, `secrets.scm` and a project's `compos.scm`: plain Scheme, read and evaluated with `eval-string-safe`, and a mistake in it reaches `*Messages*` instead of raising.

```scheme
;; ~/.compos/calendar.scm

(calendar-source! 'mac
  'provider 'macos
  'exclude  '("Birthdays" "Holidays in India")
  'writes   #t)

(calendar-source! 'fastmail
  'provider 'caldav
  'url      "https://caldav.fastmail.com/dav/calendars/user/me/personal"
  'user     "me@fastmail.com"
  'password "@FASTMAIL_APP_PASSWORD"
  'writes   #t)
```

`@NAME` is a key reference and not a key, the convention `graphql-register!` already uses. It resolves through the key chain, so the config file holds no secret and can be read by anyone.

`calendar-source!` is valid only while the config file is loading, and is an error anywhere else. So the source list has exactly one origin, and a reload replaces it rather than adding to it.

A source is one configured use of a provider. One provider can carry several sources, and one source can filter the calendars it exposes with `include` or `exclude`.

## Why the agent exists

The compos daemon is started by run_erl -daemon, so its parent is pid 1 and launchctl managername says Background. TCC never prompts a Background process, and a denied EventKit call does not raise. It returns an empty array. That failure mode looks exactly like an empty calendar, which is why it cost an hour before it was measured.

A LaunchAgent with LimitLoadToSessionType set to Aqua runs in the logged-in GUI session and can be prompted. The proof was already in ~/Library/LaunchAgents: gnu.emacs.daemon.plist, with a matching TCC row for org.gnu.Emacs.

So the daemon never calls EventKit. It writes a file and reads a file. That also gives the offline behaviour for free: a write made with the agent unloaded sits in the spool until the agent runs.

## Reading

The agent lists occurrences over a window and writes JSON to the spool. Scheme reads that JSON and rewrites the section of the text file it owns. The file is the store, in the manner of org-gcal-sync: one heading per day, one entry per event, human editable, diffable, and readable with no daemon at all.

EventKit expands recurrence for us. enumerateEventsMatchingPredicate returns occurrences, so EXDATE, RDATE and RECURRENCE-ID overrides are already resolved. That deletes the single largest piece of the original plan, roughly 400 lines of RFC 5545 that libraries routinely get wrong.

The direct SQLite read of Calendar.sqlitedb still works, needs no grant at all, and stays as the fallback for a machine where the agent is not installed. It is a fallback and not the main path for one reason: OccurrenceCache is a bounded cache of the range Calendar.app has been asked to draw, not a full expansion. It held 2553 rows ending 2026-01 while the base tables ran to 2031. Reading it as an expansion silently loses events.

## Writing

A write is a file, not a call.

| step | who | what |
| --- | --- | --- |
| 1 | daemon | writes ~/.compos/calendar/outbox/ID.json |
| 2 | agent | picks it up and runs the EventKit call |
| 3 | agent | writes ID.result, removes the request |
| 4 | daemon | reads the result, updates the text file |

One door writes to every provider, because Calendar.app owns the accounts. An event created in the Google calendar goes out through CalendarAgent's OAuth. There is no per-provider auth, ever. That is the same argument that makes the read path free, applied to writes.

A failed request keeps its result file with the error, so a write is never lost in silence.

Two verbs, and no others:

    (calendar-add! 'title "..." 'start "YYYY-MM-DD HH:MM" 'end "..."
                   'calendar "Home" 'notes "..." 'location "..." 'all-day #t)
    (calendar-remove! EVENT-ID EXPECTED-TITLE)

Four rules hold them in place. A write is only ever one event, named explicitly by the caller. No sync path writes, so a refresh can never push. `calendar-add!` needs a source whose config says `'writes #t`, and refuses when two sources both claim it rather than guessing. And `calendar-remove!` names the event and states the title it expects to find there: if the identifier has moved to another event the removal is refused, so a stale id cannot delete the wrong thing.

There is no bulk verb. On macos, changing an event means removing it and adding it, which keeps every destructive call down to one named event. The google and gog providers carry `update`, because removing and adding a Google event would cancel its invite:

    (calendar-update! EVENT-ID EXPECTED-TITLE 'start "YYYY-MM-DD HH:MM" ['end ...] ['title ...] ['notify #t] ['source ID])

It checks the title the same way `calendar-remove!` does. A new start with no end keeps the event's length. Guests hear of the change only with `'notify #t`. With more than one writing source, name one with `'source`, the `source_id` every row carries.

## The event record

    uid            the RFC 5545 UID, and the identity across every path
    event_id       the EventKit identifier, valid on this Mac only
    source         the account, for example Google or iCloud
    calendar       the calendar title
    summary        the title
    description    the body
    location
    starts_at      with an IANA time zone, or a date when all day
    ends_at        exclusive, as RFC 5545 says
    all_day?
    status         confirmed, tentative or cancelled
    transparency   busy or free
    organizer      an address
    attendees      address, role, partstat
    href, etag     CalDAV only; the Linux path fills these

uid is the identity, not event_id. That matters because the read path and the write path may differ on the same calendar, and because a Linux host reaching the same account over CalDAV must land on the same record.

## The Scheme surface :tangle calendar.scm

```scheme
;; Calendar: settings and verbs. The agent touches EventKit; this file owns policy.

(domain! 'calendar)
(effects! '(read))

(defcustom 'calendar-file "~/docs/calendar.md"
  "The text store. This file is the truth compos reads and renders.")

(defcustom 'calendar-spool "~/.compos/calendar"
  "Where the daemon and the Aqua agent leave files for each other.")

(defcustom 'calendar-agent-label "io.svs.compos-calendar"
  "The LaunchAgent label. Loaded into gui/UID, never into the daemon.")

(defcustom 'calendar-config-file "~/.compos/calendar.scm"
  "The file that declares the sources. Plain Scheme, loaded on demand.")

(defcustom 'calendar-apple-db
  "~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb"
  "Fallback read when no agent is installed. Recurrence is not expanded here.")

(defcustom 'calendar-window-back 365
  "Days before today that the text file keeps.")

(defcustom 'calendar-window-forward 730
  "Days after today that the text file keeps.")

(defcustom 'calendar-week-start 1
  "The first column of the week grid. 0 is Sunday and 1 is Monday.")
```

The verbs:

    (calendar-calendars)                  every calendar the sources reach, and its account
    (calendar-sync! [FROM TO])            refresh the window into the text file
    (calendar-events FROM TO [CALS])      the occurrences in a window
    (calendar-event-put! EVENT)           create or update; queues a request
    (calendar-event-delete! UID)
    (calendar-add! 'title ... 'start ... 'end ...)   create one event
    (calendar-remove! EVENT-ID EXPECTED-TITLE)      remove one, if it is still that one
    (calendar-agent-install!)             write the plist and bootstrap the GUI domain
    (calendar-agent-uninstall!)           bootout and remove
    (calendar-agent-status)               loaded, session, last drain, pending count
    (calendar-config-load!)               read the config file, replace the source list
    (calendar-config-path)                where that file is
    (calendar-sources)                    the configured sources, in order
    (calendar-providers)                  the registered providers

define-tool! wraps the same verbs for chat, and the compos MCP server then serves them outward. That is the real answer to a calendar MCP: one surface, every account behind it.

## The spool protocol

The daemon writes one request file and reads one result file. It never calls EventKit, because a Background process is never granted.

| path | holds |
| --- | --- |
| `~/.compos/calendar/outbox/ID.json` | the request; launchd watches this directory and wakes the agent |
| `~/.compos/calendar/results/ID.json` | the reply, written whole by a rename so a reader never sees half of one |
| `~/.compos/calendar/results/ID.err` | anything the payload wrote to stderr |
| `~/.compos/calendar/last-drain` | when the agent last ran, and which session it ran in |

A request is `{"op":"calendars"}` or `{"op":"events","from":"YYYY-MM-DD","to":"YYYY-MM-DD","calendars":[ID,...]}`. A reply always carries `ok`, and carries `error` when `ok` is false. The daemon waits `calendar-agent-timeout` seconds for the file and gives up with a message rather than hanging.

Calendars are named by identifier, never by title, so no title has to survive being escaped into JSON.

`WatchPaths` is what makes this cheap: the agent runs only when a request lands, and holds no process in between.

## The text file

`(calendar-sync!)` writes `~/docs/calendar.md`, and it will not write over a file it did not write. The first line is the mark of ownership:

    <!-- compos calendar: generated by (calendar-sync!). Edits here are replaced. -->

If that line is missing the sync refuses, says so, and changes nothing. That is checked before the events are even fetched.

The body is Markdown, one heading per day and one list item per event, which `morg-agenda-mode` and the markdown grammar already read:

    ## 2026-09-08 Tuesday

    - 11:00-11:45  Arun Devarajan - Client Meeting  `svs@svsrecruiting.com`
      https://meet.google.com/cqo-xzei-adb
    - 16:30-17:30  Out of office  `svs@svsrecruiting.com`

## Commands

| command | what it does |
| --- | --- |
| `calendar` | refresh the file and show it in the other window |
| `calendar-sync` | refresh the file, and say how many events landed |
| `calendar-add-event` | title, start, minutes, then the calendar; creates it and refreshes |
| `calendar-agent-status` | loaded or absent, the last drain, and how many requests are waiting |
| `calendar-agent-install` | install the LaunchAgent into the GUI session |
| `calendar-reload-config` | read `~/.compos/calendar.scm` again |

`calendar-add-event` offers only calendars that EventKit reports as writable, so a subscribed or holiday calendar is never on the list. Minutes defaults to 60 and the start defaults to today, so the usual event is four keystrokes and two RETs.

No keys are bound. A binding is the user's to choose, and `(global-set-key "C-c c" "calendar")` in `~/.compos/init.scm` is the whole of it.

## Payload choice

The payload is what the agent runs. It is a cheap and reversible choice, because everything sits behind the spool.

| payload | build | risk |
| --- | --- | --- |
| JXA through osascript | none | the async grant callback does not fire, see landmines |
| sichengchen/tap/apple-calendar-cli | Swift source build, no bottle, needs Xcode | third-party binary, 6 stars, last push 2026-02 |
| @joargp/accli on npm | none, npx | unknown author, reads your calendar |

JXA is in use and works. apple-calendar-cli covers list, get, create, update, delete, recurrence, alerts and --json, so it is the drop-in if JXA turns awkward, at the cost of compiling Swift once through brew.

## Linux

Linux has no OS calendar. Evolution Data Server over D-Bus is GNOME-only and worse than what it replaces. What Linux users actually run is vdirsyncer writing a vdir, a directory of .ics files.

So Linux gets a separate importer into the same text file: CalDAV directly, or an existing vdir. The text store absorbs the difference, and no view knows which host produced a row. iCloud, Fastmail and Nextcloud take an app password. Google does not, and there CalDAV is the worse of the two Google doors, since the REST API gives sync tokens and JSON instead of XML and sync-collection.

## Phases

| phase | what | state |
| --- | --- | --- |
| P1 | the provider seam, the config file, the agent probes | seam and config load in the live session; the install and drain verbs are still to write |
| P2 | read into the text file through the spool | done: 10 calendars, 6 configured, 39 events written |
| P3 | views: agenda merge, then the week grid | next; morg-agenda-mode already does most of it |
| P4 | writing: create and remove, through the same spool | done: an event was created in Home, read back, removed, and confirmed gone from the SQLite file |
| P5 | Linux importer over CalDAV or a vdir | |
| P6 | mirroring between calendars, full or busy-only, with a link map | |
| P7 | freebusy and RSVP | |

gog is back as a provider, beside google. Both reach one Google account without the Aqua agent, and both can update an event in place. macOS still reaches every account at once.

## Landmines

Every one of these fails silently into an empty calendar rather than an error, which is why they are written down.

| landmine | what happens |
| --- | --- |
| the Background session | EventKit returns an empty array with no error. Check launchctl managername before believing an empty result |
| SQLite number against text | a comparison of a numeric column against a text literal never matches, and returns zero rows |
| OccurrenceCache | a bounded UI cache, not an expansion. It stopped at 2026-01 while the base tables ran to 2031 |
| CFAbsoluteTime | the SQLite path stores seconds from 2001-01-01. Add 978307200 |
| floating time zones | a floating or all-day time has no zone, and start_tz reads _float. Do not coerce it to local |
| the JXA grant callback | requestFullAccessToEventsWithCompletion never fired its block in the probe, and granted stayed null. Access still worked. Judge access by whether calendars come back, not by that flag |
| stale delete readback | after removeEventSpanError, eventWithIdentifier still returned the object. Verify a delete with a fresh store or against the SQLite file |
| the TCC row is a path | the grant is recorded against /bin/zsh as a path, client_type 1. Change the interpreter and the grant is gone |
| the schema is not a contract | Calendar.sqlitedb carries no promise across macOS releases. Probe it, do not trust it |
| the SQLite calendar list | Calendar.sqlitedb lists 20 calendars where EventKit shows 10. Default, Found in Mail, Found in Natural Language and Facebook Birthdays are internal. Filter by store, and drop the Default store |
| dotted rest arguments | this Scheme takes `&rest`, and a dotted formal binds the last argument instead of the tail. It fails quietly, with no error |
| sort takes one argument | `(sort LIST)` only. There is no comparator argument and no `string<?`. `<` compares strings, so a keyed sort has to be written by hand |
| NSArray from a JS array | `$.NSArray.arrayWithArray` on a JS array of ObjC wrappers throws `unrecognized selector ... backingObject`. Build an `NSMutableArray` and `addObject` instead |
| reading the result too soon | launchd fires the watch quickly but not instantly. A read straight after writing the request finds nothing. Poll for the result file |
| json-parse turns null into #f | an absent location and a location of `false` are the same value afterwards |
| no task-run! at load | the package registers verbs at load and starts nothing |
| define-list-mode! caches | a new option key needs the definition re-run. A hot reload alone does not reach the mode |

## Open decisions

1. Where the text file lives, and whether it is one file or one per month. One file is simpler, and the window bounds its size.
2. Whether the write path targets defaultCalendarForNewEvents or asks, when the account is ambiguous.
3. Whether a compos edit to the text file pushes back to the calendar, or whether the file is read-only for events and writes go through the verbs. Two-way text editing is the more Emacs answer and the more dangerous one.
4. Whether the agent runs on an interval or only on demand. On demand is cheaper and makes the file stale between uses.
