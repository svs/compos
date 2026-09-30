;; Calendar: settings and verbs. The agent touches EventKit; this file owns policy.
;; Tangled from README.md.

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

;; Days before today that the text file keeps.
(define calendar-window-back 365)

;; Days after today that the text file keeps.
(define calendar-window-forward 730)

(defcustom 'calendar-week-start 1
  "The first column of the week grid. 0 is Sunday and 1 is Monday.")

;; Seconds to wait for the Aqua agent to answer one request.
(define calendar-agent-timeout 20)

(defcustom 'calendar-agent-directory
  (string-append (compos-project-dir) "/scheme/packages/calendar/agent")
  "Where the agent's plist and payloads live.")

;; A plist reader that answers #f for a missing key instead of throwing.

(define (calendar--prop plist key)
  (cond ((null? plist) #f)
        ((null? (cdr plist)) #f)
        ((equal? (car plist) key) (car (cdr plist)))
        (else (calendar--prop (cdr (cdr plist)) key))))

;; Providers. macos is one of these, not the design.

(define *calendar-providers* '())

(define (calendar-provider-define! name &rest props)
  (set! *calendar-providers*
        (cons (cons name props)
              (remove (lambda (p) (equal? (car p) name)) *calendar-providers*)))
  name)

(define (calendar-provider name)
  (let ((hit (assoc name *calendar-providers*)))
    (and hit (cdr hit))))

(define (calendar-providers) (map car *calendar-providers*))

(define (calendar-provider-can? name what)
  (let ((props (calendar-provider name)))
    (and props (member what (calendar--prop props 'capabilities)) #t)))

;; Sources come from the config file, and from nowhere else.

(define *calendar-sources* '())
(define *calendar-config-loading* #f)

(define (calendar-source! id &rest plist)
  (if (not *calendar-config-loading*)
      (error "calendar-source! belongs in the calendar config file")
      (begin (set! *calendar-sources* (cons (cons id plist) *calendar-sources*))
             id)))

(define (calendar-sources) (reverse *calendar-sources*))

(define (calendar-source id)
  (let ((hit (assoc id *calendar-sources*)))
    (and hit (cdr hit))))

(define (calendar-source-provider id)
  (calendar--prop (calendar-source id) 'provider))

(define (calendar--expand path)
  (if (string-prefix? "~/" path)
      (string-append (getenv "HOME") (substring path 1 (string-length path)))
      path))

(define (calendar-config-path) (calendar--expand calendar-config-file))

(define (calendar-config-load!)
  (let ((path (calendar-config-path)))
    (set! *calendar-sources* '())
    (if (not (file-exists? path))
        '()
        (begin
          (set! *calendar-config-loading* #t)
          (let ((result (eval-string-safe (read-file path))))
            (set! *calendar-config-loading* #f)
            (if (equal? (car result) 'ok)
                (calendar-sources)
                (begin (message (string-append "calendar.scm: "
                                               (value->string (car (cdr result)))))
                       #f)))))))

;; The macOS providers. The probes settled their capabilities; the functions
;; arrive with P2. macos is one provider among several, not the design.

(calendar-provider-define! 'macos
  'calendars    (lambda (src) (calendar--macos-calendars src))
  'events       (lambda (src from to) (calendar--macos-events src from to))
  'put!         (lambda (src event) (calendar--macos-put! src event))
  'delete!      (lambda (src id expect) (calendar--macos-remove! src id expect))
  'capabilities '(read write expanded)
  'reaches      "every account Calendar.app holds"
  'needs        "the Aqua LaunchAgent")

(calendar-provider-define! 'macos-db
  'capabilities '(read)
  'reaches      "the same accounts, read straight from Calendar.sqlitedb"
  'needs        "nothing")

;; The spool. The daemon writes a request and reads a result; it never calls
;; EventKit, because a Background process is never granted.

(define *calendar-request-n* 0)

(define (calendar--spool) (calendar--expand calendar-spool))

(define (calendar--request! json)
  (set! *calendar-request-n* (+ 1 *calendar-request-n*))
  (let* ((spool (calendar--spool))
         (id (string-append "req" (number->string *calendar-request-n*)))
         (req (string-append spool "/outbox/" id ".json"))
         (res (string-append spool "/results/" id ".json"))
         (err (string-append spool "/results/" id ".err"))
         (cmd (string-append
               "mkdir -p " (sh-quote (string-append spool "/outbox")) " "
                            (sh-quote (string-append spool "/results"))
               "; rm -f " (sh-quote res) " " (sh-quote err)
               "; printf %s " (sh-quote json) " > " (sh-quote req)
               "; for i in $(seq 1 " (number->string (* 20 calendar-agent-timeout)) "); do"
               " [ -f " (sh-quote res) " ] && break; sleep 0.05; done"
               "; cat " (sh-quote res) " 2>/dev/null"))
         (out (shell-command->string cmd (getenv "HOME"))))
    (cond ((equal? out "")
           (message "calendar: no answer from the agent; try (calendar-agent-install!)")
           #f)
          (else
           (let ((val (json-parse out)))
             (cond ((not val) (message "calendar: unreadable agent reply") #f)
                   ((calendar--prop val 'ok) val)
                   (else (message (string-append "calendar: "
                                                 (value->string (calendar--prop val 'error))))
                         #f)))))))

(define (calendar--json-ids ids)
  (string-append "[" (string-join (map (lambda (s) (string-append "\"" s "\"")) ids) ",") "]"))

;; The macos provider's own functions. Nothing calls these directly; the
;; verbs below reach them through the provider a source names.

(define (calendar--macos-calendars src)
  (let ((r (calendar--request! "{\"op\":\"calendars\"}")))
    (if r (calendar--prop r 'calendars) '())))

(define (calendar--source-wants? plist row)
  (let ((title (calendar--prop row 'title))
        (inc (calendar--prop plist 'include))
        (exc (calendar--prop plist 'exclude)))
    (and (or (not inc) (member title inc) #f)
         (not (and exc (member title exc) #t)))))

(define (calendar--wanted? row sources)
  (cond ((null? sources) #f)
        ((calendar--source-wants? (cdr (car sources)) row) #t)
        (else (calendar--wanted? row (cdr sources)))))

(define (calendar--source-calendars src)
  (filter (lambda (row) (calendar--source-wants? (calendar-source src) row))
          (calendar--macos-calendars src)))

(define (calendar--macos-events src from to)
  (let* ((cals (calendar--source-calendars src))
         (ids (map (lambda (r) (calendar--prop r 'id)) cals))
         (json (string-append "{\"op\":\"events\",\"from\":\"" from
                              "\",\"to\":\"" to "\",\"calendars\":"
                              (calendar--json-ids ids) "}"))
         (r (calendar--request! json)))
    (if r (calendar--prop r 'events) '())))

;; The verbs. Each one walks the configured sources and dispatches to whichever
;; provider that source names, so nothing above this line knows about macOS.

(define (calendar--provider-fn source-id key)
  (let ((p (calendar-source-provider source-id)))
    (and p (calendar--prop (calendar-provider p) key))))

(define (calendar--gather sources f)
  (if (null? sources)
      '()
      (append (f (car sources)) (calendar--gather (cdr sources) f))))

(define (calendar--before? a b)
  (< (calendar--prop a 'starts_at) (calendar--prop b 'starts_at)))

(define (calendar--sort-events rows)
  (if (null? rows)
      '()
      (let ((pivot (car rows)) (rest (cdr rows)))
        (append (calendar--sort-events (filter (lambda (r) (calendar--before? r pivot)) rest))
                (list pivot)
                (calendar--sort-events (filter (lambda (r) (not (calendar--before? r pivot))) rest))))))

(define (calendar-calendars)
  (calendar--gather
   (calendar-sources)
   (lambda (s)
     (let ((fn (calendar--provider-fn (car s) 'calendars)))
       (if fn
           (filter (lambda (row) (calendar--source-wants? (cdr s) row)) (fn (car s)))
           '())))))

(define (calendar-events from to)
  (let ((rows (calendar--gather
               (calendar-sources)
               (lambda (s)
                 (let ((fn (calendar--provider-fn (car s) 'events)))
                   (if fn
                       (map (lambda (row) (cons 'source_id (cons (car s) row)))
                            (fn (car s) from to))
                       '()))))))
    (calendar--sort-events rows)))

;; The agent itself.

(define (calendar--agent-plist)
  (string-append calendar-agent-directory "/" calendar-agent-label ".plist"))

(define (calendar-agent-install!)
  (shell-command->string
   (string-append "mkdir -p " (sh-quote (string-append (calendar--spool) "/outbox")) " "
                  (sh-quote (string-append (calendar--spool) "/results"))
                  "; launchctl bootout gui/$(id -u)/" calendar-agent-label " 2>/dev/null"
                  "; launchctl bootstrap gui/$(id -u) " (sh-quote (calendar--agent-plist)) " 2>&1")
   (getenv "HOME"))
  (calendar-agent-status))

(define (calendar-agent-uninstall!)
  (shell-command->string
   (string-append "launchctl bootout gui/$(id -u)/" calendar-agent-label " 2>&1")
   (getenv "HOME"))
  (calendar-agent-status))

(define (calendar-agent-status)
  (let* ((spool (calendar--spool))
         (out (shell-command->string
               (string-append
                "launchctl print gui/$(id -u)/" calendar-agent-label
                " >/dev/null 2>&1 && echo loaded || echo absent"
                "; cat " (sh-quote (string-append spool "/last-drain")) " 2>/dev/null || echo never"
                "; ls " (sh-quote (string-append spool "/outbox")) " 2>/dev/null | wc -l | tr -d ' '")
               (getenv "HOME")))
         (lines (string-split (string-trim out) "\n")))
    (list 'agent (car lines)
          'last-drain (if (> (length lines) 2) (car (cdr lines)) "never")
          'pending (car (reverse lines))
          'session (string-trim (shell-command->string "launchctl managername" (getenv "HOME")))
          'plist (calendar--agent-plist))))

;; The text store. The file is generated, and the sync refuses to write over
;; anything it did not write itself.

(define *calendar-file-header*
  "<!-- compos calendar: generated by (calendar-sync!). Edits here are replaced. -->")

(define (calendar--file) (calendar--expand calendar-file))

(define (calendar-file-ours?)
  (let ((path (calendar--file)))
    (or (not (file-exists? path))
        (string-prefix? *calendar-file-header* (read-file path)))))

(define (calendar--today)
  (string-trim (shell-command->string "date +%F" (getenv "HOME"))))

(define (calendar--date-plus days)
  (string-trim (shell-command->string
                (string-append "date -v+" (number->string days) "d +%F")
                (getenv "HOME"))))

(define (calendar--event-line e)
  (let ((all-day (calendar--prop e 'all_day))
        (starts (calendar--prop e 'starts))
        (ends (calendar--prop e 'ends))
        (summary (calendar--prop e 'summary))
        (cal (calendar--prop e 'calendar))
        (loc (calendar--prop e 'location)))
    (string-append "- " (if all-day "all day" (string-append starts "-" ends))
                   "  " (if summary summary "(no title)")
                   "  `" (if cal cal "?") "`"
                   (if loc (string-append "\n  " loc) "")
                   "\n")))

(define (calendar--body events day out)
  (if (null? events)
      (apply string-append (reverse out))
      (let* ((e (car events))
             (d (calendar--prop e 'day))
             (head (if (equal? d day)
                       ""
                       (string-append "\n## " d " "
                                      (let ((w (calendar--prop e 'weekday))) (if w w ""))
                                      "\n\n"))))
        (calendar--body (cdr events) d
                        (cons (string-append head (calendar--event-line e)) out)))))

(define (calendar-render from to events)
  (string-append *calendar-file-header* "\n\n# Calendar\n\n"
                 from " to " to ", " (number->string (length events)) " events.\n"
                 (calendar--body events #f '())))

(define (calendar-sync! &rest range)
  (let* ((from (if (null? range) (calendar--today) (car range)))
         (to (if (or (null? range) (null? (cdr range)))
                 (calendar--date-plus 30)
                 (car (cdr range))))
         (path (calendar--file)))
    (if (not (calendar-file-ours?))
        (begin (message (string-append "calendar: " path
                                       " was not written by compos; refusing to replace it"))
               #f)
        (let ((events (calendar-events from to)))
          (if (not events)
              #f
              (let ((text (calendar-render from to events)))
                (find-file path)
                (buffer-delete-range! path 0 (string-length (buffer-text path)))
                (buffer-append! path text)
                (with-current-buffer path (lambda () (buffer-save!)))
                (list 'file path 'from from 'to to 'events (length events))))))))

;; Writing. One event at a time, named explicitly, never from a sync path.

(define (calendar--json-escape s)
  (let loop ((i 0) (out ""))
    (if (>= i (string-length s))
        out
        (let ((c (substring s i (+ i 1))))
          (loop (+ i 1)
                (string-append out
                               (cond ((equal? c "\"") "\\\"")
                                     ((equal? c "\\") "\\\\")
                                     ((equal? c "\n") "\\n")
                                     ((equal? c "\t") "\\t")
                                     (else c))))))))

(define (calendar--json-str s)
  (string-append "\"" (calendar--json-escape s) "\""))

(define (calendar--json-pair key value)
  (string-append (calendar--json-str key) ":"
                 (cond ((equal? value #t) "true")
                       ((equal? value #f) "false")
                       (else (calendar--json-str value)))))

(define (calendar--json-object pairs)
  (string-append "{" (string-join pairs ",") "}"))

(define (calendar--macos-put! src event)
  (let* ((title (calendar--prop event 'title))
         (start (calendar--prop event 'start))
         (end (calendar--prop event 'end))
         (cal (calendar--prop event 'calendar))
         (notes (calendar--prop event 'notes))
         (loc (calendar--prop event 'location))
         (all-day (calendar--prop event 'all-day))
         (pairs (append (list (calendar--json-pair "op" "create")
                              (calendar--json-pair "title" title)
                              (calendar--json-pair "start" start)
                              (calendar--json-pair "end" end))
                        (if cal (list (calendar--json-pair "calendar" cal)) '())
                        (if notes (list (calendar--json-pair "notes" notes)) '())
                        (if loc (list (calendar--json-pair "location" loc)) '())
                        (if all-day (list (calendar--json-pair "all_day" #t)) '()))))
    (calendar--request! (calendar--json-object pairs))))

(define (calendar--macos-remove! src event-id expect)
  (calendar--request!
   (calendar--json-object (list (calendar--json-pair "op" "remove")
                                (calendar--json-pair "event_id" event-id)
                                (calendar--json-pair "expect" expect)))))

(define (calendar--writing-source)
  (let ((writers (filter (lambda (s) (calendar--prop (cdr s) 'writes)) (calendar-sources))))
    (cond ((null? writers)
           (message "calendar: no source in the config file says 'writes #t")
           #f)
          ((not (null? (cdr writers)))
           (message "calendar: more than one source writes; name one with 'source")
           #f)
          (else (car (car writers))))))

(define (calendar-add! &rest event)
  (let ((title (calendar--prop event 'title))
        (start (calendar--prop event 'start))
        (end (calendar--prop event 'end))
        (src (let ((named (calendar--prop event 'source)))
               (if named named (calendar--writing-source)))))
    (cond ((not (and title start end))
           (message "calendar-add!: needs 'title, 'start and 'end")
           #f)
          ((not src) #f)
          ((not (calendar-provider-can? (calendar-source-provider src) 'write))
           (message "calendar: that source's provider cannot write")
           #f)
          (else
           (let ((fn (calendar--provider-fn src 'put!)))
             (if (not fn)
                 (begin (message "calendar: that provider has no put!") #f)
                 (fn src event)))))))

(define (calendar-remove! event-id expect &optional source)
  (let ((src (if source source (calendar--writing-source))))
    (if (not src)
        #f
        (let ((fn (calendar--provider-fn src 'delete!)))
          (if (not fn)
              (begin (message "calendar: that provider has no delete!") #f)
              (fn src event-id expect))))))

;; The M-x surface. Everything above is callable from Scheme; this is what a
;; person reaches for.

;; ---- Google Calendar: the google and gog providers ------------------------
;; Both speak the Google Calendar API and hand back the same event JSON, so
;; they share the rows and differ only in the transport: google calls REST
;; through the editor's own OAuth connection (google-connect), gog shells out
;; to the gog CLI and its keychain token. A row's event_id is CALENDAR|ID.

(domain! 'calendar)
(effects! '(write external))

(define *calendar-zone* #f)

(define (calendar--zone)
  (if (not *calendar-zone*)
      (let ((lines (string-split (string-trim (shell-command->string
                                               "date +%z; readlink /etc/localtime"
                                               (getenv "HOME")))
                                 "\n")))
        (set! *calendar-zone*
              (list (let ((z (car lines)))
                      (string-append (substring z 0 3) ":" (substring z 3 5)))
                    (car (reverse (string-split (car (cdr lines)) "zoneinfo/")))))))
  *calendar-zone*)

(define (calendar--offset) (car (calendar--zone)))
(define (calendar--iana) (car (cdr (calendar--zone))))

(define (calendar--rfc3339 stamp)
  (string-append (substring stamp 0 10) "T"
                 (if (> (string-length stamp) 10) (substring stamp 11 16) "00:00")
                 ":00" (calendar--offset)))

(define (calendar--stamp->secs stamp)
  (let ((timed (> (string-length stamp) 10)))
    (parts->time (string->number (substring stamp 0 4))
                 (string->number (substring stamp 5 7))
                 (string->number (substring stamp 8 10))
                 (if timed (string->number (substring stamp 11 13)) 0)
                 (if timed (string->number (substring stamp 14 16)) 0))))

(define (calendar--gtime e key)
  (let* ((local (calendar--prop e (if (equal? key 'start) 'startLocal 'endLocal)))
         (t (calendar--prop e key))
         (dt (or local (and t (calendar--prop t 'dateTime)))))
    (if dt
        (list (substring dt 0 10) (substring dt 11 16))
        (list (and t (calendar--prop t 'date)) #f))))

(define (calendar--google-row cal-id cal-title e)
  (let* ((s (calendar--gtime e 'start))
         (en (calendar--gtime e 'end))
         (all-day (not (car (cdr s))))
         (org (calendar--prop e 'organizer))
         (people (calendar--prop e 'attendees)))
    (list 'event_id (string-append cal-id "|" (calendar--prop e 'id))
          'uid (calendar--prop e 'iCalUID)
          'summary (calendar--prop e 'summary)
          'description (calendar--prop e 'description)
          'location (calendar--prop e 'location)
          'calendar cal-title
          'account "Google"
          'all_day all-day
          'day (car s)
          'weekday (and (car s) (format-time (calendar--stamp->secs (car s)) "%A"))
          'starts (car (cdr s))
          'ends (car (cdr en))
          'starts_at (if all-day (car s) (string-append (car s) " " (car (cdr s))))
          'ends_at (if all-day (car en) (string-append (car en) " " (car (cdr en))))
          'status (calendar--prop e 'status)
          'organizer (and org (calendar--prop org 'email))
          'attendees (if people (map (lambda (a) (calendar--prop a 'email)) people) '())
          'url (or (calendar--prop e 'hangoutLink) (calendar--prop e 'htmlLink)))))

(define (calendar--g-when stamp all-day)
  (if all-day
      (list 'date (substring stamp 0 10))
      (list 'dateTime (calendar--rfc3339 stamp) 'timeZone (calendar--iana))))

(define (calendar--g-body event)
  (let ((all-day (calendar--prop event 'all-day))
        (pick (lambda (key field)
                (let ((v (calendar--prop event key))) (if v (list field v) '())))))
    (append (pick 'title 'summary)
            (pick 'notes 'description)
            (pick 'location 'location)
            (let ((s (calendar--prop event 'start)))
              (if s (list 'start (calendar--g-when s all-day)) '()))
            (let ((e (calendar--prop event 'end)))
              (if e (list 'end (calendar--g-when e all-day)) '()))
            (let ((a (calendar--prop event 'attendees)))
              (if a (list 'attendees (map (lambda (x) (list 'email x)) a)) '())))))

(define (calendar--notify event) (if (calendar--prop event 'notify) "all" "none"))

(define (calendar--google-account src)
  (let* ((want (calendar--prop (calendar-source src) 'account))
         (hit (filter (lambda (a) (or (not want)
                                      (equal? want (calendar--prop a 'email))
                                      (equal? want (calendar--prop a 'id))))
                      (google-accounts))))
    (and (not (null? hit)) (calendar--prop (car hit) 'id))))

(define (calendar--google-call src op args)
  (let* ((acct (calendar--google-account src))
         (base "https://www.googleapis.com/calendar/v3")
         (events (lambda () (string-append base "/calendars/" (url-encode (car args)) "/events")))
         (one (lambda () (string-append (events) "/" (url-encode (list-ref args 1)))))
         (r (cond ((not acct) '(ok #f error "no connected Google account; run google-connect"))
                  ((equal? op 'calendars)
                   (google-http! acct "GET" (string-append base "/users/me/calendarList")
                                 '(maxResults "250") #f))
                  ((equal? op 'events)
                   (google-http! acct "GET" (events)
                                 (list 'timeMin (calendar--rfc3339 (list-ref args 1))
                                       'timeMax (string-append (list-ref args 2) "T23:59:59"
                                                               (calendar--offset))
                                       'singleEvents "true" 'orderBy "startTime"
                                       'maxResults "250" 'timeZone (calendar--iana))
                                 #f))
                  ((equal? op 'get)
                   (google-http! acct "GET" (one) (list 'timeZone (calendar--iana)) #f))
                  ((equal? op 'insert)
                   (google-http! acct "POST" (events) (list 'sendUpdates (list-ref args 2))
                                 (list-ref args 1)))
                  ((equal? op 'patch)
                   (google-http! acct "PATCH" (one) (list 'sendUpdates (list-ref args 3))
                                 (list-ref args 2)))
                  ((equal? op 'delete)
                   (google-http! acct "DELETE" (one) (list 'sendUpdates (list-ref args 2)) #f))
                  (else '(ok #f error "unknown calendar op")))))
    (if (not (calendar--prop r 'ok))
        (begin (message (string-append "calendar: " (value->string (calendar--prop r 'error))))
               #f)
        (let ((data (calendar--prop r 'data)))
          (cond ((member op '(calendars events)) (or (and data (calendar--prop data 'items)) '()))
                (data data)
                (else #t))))))

(define (calendar--gog-flags body)
  (let ((s (calendar--prop body 'start))
        (e (calendar--prop body 'end))
        (people (calendar--prop body 'attendees))
        (flag (lambda (name v) (if v (string-append " --" name "=" (sh-quote v)) ""))))
    (string-append (flag "summary" (calendar--prop body 'summary))
                   (flag "description" (calendar--prop body 'description))
                   (flag "location" (calendar--prop body 'location))
                   (flag "from" (and s (or (calendar--prop s 'dateTime) (calendar--prop s 'date))))
                   (flag "to" (and e (or (calendar--prop e 'dateTime) (calendar--prop e 'date))))
                   (if (and s (calendar--prop s 'date)) " --all-day" "")
                   (flag "attendees" (and people (string-join (map (lambda (p) (calendar--prop p 'email))
                                                                   people)
                                                              ","))))))

(define (calendar--gog-call src op args)
  (let* ((acct (calendar--prop (calendar-source src) 'account))
         (q sh-quote)
         (sub (cond ((equal? op 'calendars) "calendars --max=250")
                    ((equal? op 'events)
                     (string-append "events " (q (car args))
                                    " --from=" (q (calendar--rfc3339 (list-ref args 1)))
                                    " --to=" (q (string-append (list-ref args 2) "T23:59:59"
                                                               (calendar--offset)))
                                    " --max=250"))
                    ((equal? op 'get) (string-append "event " (q (car args)) " " (q (list-ref args 1))))
                    ((equal? op 'insert)
                     (string-append "create " (q (car args)) (calendar--gog-flags (list-ref args 1))
                                    " --send-updates=" (list-ref args 2)))
                    ((equal? op 'patch)
                     (string-append "update " (q (car args)) " " (q (list-ref args 1))
                                    (calendar--gog-flags (list-ref args 2))
                                    " --send-updates=" (list-ref args 3)))
                    ((equal? op 'delete)
                     (string-append "delete " (q (car args)) " " (q (list-ref args 1))
                                    " --force --send-updates=" (list-ref args 2)))))
         (out (shell-command->string
               (string-append "gog --no-input --json --results-only"
                              (if acct (string-append " --account=" (q acct)) "")
                              " calendar " sub " || echo __gog_failed")
               (getenv "HOME")))
         (v (json-parse out)))
    (cond ((string-contains? out "__gog_failed")
           (message (string-append "calendar: gog: "
                                   (string-trim (car (string-split out "__gog_failed")))))
           #f)
          ((member op '(calendars events))
           (cond ((not (pair? v)) '())
                 ((symbol? (car v)) (or (calendar--prop v 'items) (calendar--prop v 'events)
                                        (calendar--prop v 'calendars) '()))
                 (else v)))
          ((pair? v) (or (calendar--prop v 'event) v))
          (else #t))))

(define (calendar--gcal src op &rest args)
  (let ((fn (calendar--provider-fn src 'transport)))
    (and fn (fn src op args))))

(define (calendar--g-calendars src)
  (map (lambda (c)
         (list 'id (calendar--prop c 'id)
               'title (calendar--prop c 'summary)
               'account "Google"
               'writable (and (member (calendar--prop c 'accessRole) '("owner" "writer")) #t)
               'selected (calendar--prop c 'selected)
               'primary (calendar--prop c 'primary)))
       (or (calendar--gcal src 'calendars) '())))

(define (calendar--g-wanted src)
  (let ((plist (calendar-source src)))
    (filter (lambda (row)
              (and (calendar--source-wants? plist row)
                   (or (calendar--prop plist 'include)
                       (calendar--prop row 'selected)
                       (calendar--prop row 'primary))))
            (calendar--g-calendars src))))

(define (calendar--g-events src from to)
  (calendar--gather
   (calendar--g-wanted src)
   (lambda (c)
     (map (lambda (e) (calendar--google-row (calendar--prop c 'id) (calendar--prop c 'title) e))
          (or (calendar--gcal src 'events (calendar--prop c 'id) from to) '())))))

(define (calendar--g-calendar-id src name)
  (if (not name)
      "primary"
      (let ((hit (filter (lambda (c) (or (equal? name (calendar--prop c 'title))
                                         (equal? name (calendar--prop c 'id))))
                         (calendar--g-calendars src))))
        (if (null? hit) name (calendar--prop (car hit) 'id)))))

(define (calendar--g-put! src event)
  (let* ((cal (calendar--g-calendar-id src (calendar--prop event 'calendar)))
         (made (calendar--gcal src 'insert cal (calendar--g-body event) (calendar--notify event))))
    (if (pair? made)
        (calendar--google-row cal (or (calendar--prop event 'calendar) cal) made)
        made)))

(define (calendar--g-find src event-id expect)
  (let* ((parts (string-split event-id "|"))
         (cal (car parts))
         (id (if (null? (cdr parts)) #f (car (cdr parts))))
         (ev (and id (calendar--gcal src 'get cal id))))
    (cond ((not (pair? ev)) (message (string-append "calendar: no event " event-id)) #f)
          ((not (equal? (calendar--prop ev 'summary) expect))
           (message (string-append "calendar: that event is now titled "
                                   (value->string (calendar--prop ev 'summary))
                                   ", not " expect))
           #f)
          (else (list cal id ev)))))

(define (calendar--g-delete! src event-id expect)
  (let ((hit (calendar--g-find src event-id expect)))
    (and hit
         (calendar--gcal src 'delete (car hit) (car (cdr hit)) "none")
         (list 'ok #t 'op "remove" 'event_id event-id 'summary expect))))

(define (calendar--keep-length ev changes)
  (let ((start (calendar--prop changes 'start))
        (s (calendar--gtime ev 'start))
        (e (calendar--gtime ev 'end)))
    (if (or (not start) (calendar--prop changes 'end) (not (car (cdr s))))
        changes
        (let ((len (- (calendar--stamp->secs (string-append (car e) " " (car (cdr e))))
                      (calendar--stamp->secs (string-append (car s) " " (car (cdr s)))))))
          (append changes
                  (list 'end (format-time (+ (calendar--stamp->secs start) len)
                                          "%Y-%m-%d %H:%M")))))))

(define (calendar--g-update! src event-id expect changes)
  (let ((hit (calendar--g-find src event-id expect)))
    (and hit
         (let* ((cal (car hit))
                (changes (calendar--keep-length (list-ref hit 2) changes))
                (made (calendar--gcal src 'patch cal (car (cdr hit))
                                      (calendar--g-body changes) (calendar--notify changes))))
           (if (pair? made) (calendar--google-row cal cal made) made)))))

(calendar-provider-define! 'google
  'transport    (lambda (src op args) (calendar--google-call src op args))
  'calendars    (lambda (src) (calendar--g-calendars src))
  'events       (lambda (src from to) (calendar--g-events src from to))
  'put!         (lambda (src event) (calendar--g-put! src event))
  'delete!      (lambda (src id expect) (calendar--g-delete! src id expect))
  'update!      (lambda (src id expect changes) (calendar--g-update! src id expect changes))
  'capabilities '(read write update expanded)
  'reaches      "one Google account, over REST"
  'needs        "google-connect with the calendar scope")

(calendar-provider-define! 'gog
  'transport    (lambda (src op args) (calendar--gog-call src op args))
  'calendars    (lambda (src) (calendar--g-calendars src))
  'events       (lambda (src from to) (calendar--g-events src from to))
  'put!         (lambda (src event) (calendar--g-put! src event))
  'delete!      (lambda (src id expect) (calendar--g-delete! src id expect))
  'update!      (lambda (src id expect changes) (calendar--g-update! src id expect changes))
  'capabilities '(read write update expanded)
  'reaches      "one Google account, through the gog CLI"
  'needs        "gog auth for that account")

(define (calendar-update! event-id expect &rest changes)
  (let ((src (let ((named (calendar--prop changes 'source)))
               (if named named (calendar--writing-source)))))
    (cond ((not src) #f)
          ((not (calendar-provider-can? (calendar-source-provider src) 'update))
           (message "calendar: that source cannot update; remove and add instead")
           #f)
          (else ((calendar--provider-fn src 'update!) src event-id expect changes)))))

(domain! 'calendar)
(effects! '(write display))

;; ---- calendar-mode: the days on screen, fetched in the background -----------
;; The view asks the sources for its own days only, so opening it costs one
;; small query and not a month. Pages already fetched come back from a cache
;; until g refreshes them.


(define *calendar-view-buffer* "*calendar*")
(define *calendar-view-cache* '())

(define (calendar--now-day) (format-time (current-time) "%Y-%m-%d"))

(define (calendar--day-add day n)
  (format-time (time+ (calendar--stamp->secs day) n) "%Y-%m-%d"))

(define (calendar--day-label day)
  (format-time (calendar--stamp->secs day) "%A %d %B"))

(define (calendar--view-start buf)
  (or (buffer-local buf 'calendar-start) (calendar--now-day)))

(defcustom 'calendar-view-span "week"
  "What calendar-mode opens on: day, week or month.")

(define (calendar--view-span buf)
  (or (buffer-local buf 'calendar-span) calendar-view-span))

(define (calendar--month-first day) (string-append (substring day 0 8) "01"))

(define (calendar--month-length first)
  (let loop ((n 28))
    (if (or (= n 31) (not (equal? (substring (calendar--day-add first n) 5 7)
                                  (substring first 5 7))))
        n
        (loop (+ n 1)))))

;; the days a view shows, as (FROM N): the anchor day is any day inside
(define (calendar--view-range buf)
  (let ((anchor (calendar--view-start buf))
        (span (calendar--view-span buf)))
    (cond ((equal? span "day") (list anchor 1))
          ((equal? span "month")
           (let ((first (calendar--month-first anchor)))
             (list first (calendar--month-length first))))
          (else
           (let* ((dow (list-ref (time->parts (calendar--stamp->secs anchor)) 5))
                  (back (modulo (- (modulo dow 7) calendar-week-start) 7)))
             (list (calendar--day-add anchor (- 0 back)) 7))))))

(define (calendar--view-title buf)
  (let* ((r (calendar--view-range buf))
         (from (car r))
         (span (calendar--view-span buf)))
    (cond ((equal? span "day") (calendar--day-label from))
          ((equal? span "month") (format-time (calendar--stamp->secs from) "%B %Y"))
          (else (string-append (format-time (calendar--stamp->secs from) "%d %b") " to "
                               (format-time (calendar--stamp->secs
                                             (calendar--day-add from (- (car (cdr r)) 1)))
                                            "%d %b %Y"))))))

(define (calendar--view-step-period! buf dir)
  (let* ((r (calendar--view-range buf))
         (from (car r))
         (span (calendar--view-span buf)))
    (calendar--view-move! buf
      (cond ((equal? span "month")
             (if (> dir 0)
                 (calendar--day-add from (car (cdr r)))
                 (calendar--month-first (calendar--day-add from -1))))
            (else (calendar--day-add from (* dir (car (cdr r)))))))))

(define (calendar--view-set-span! buf span)
  (buffer-set-local! buf 'calendar-span span)
  (calendar--view-fetch! buf))

(define (calendar--view-line e)
  (string-append "  "
                 (if (calendar--prop e 'all_day)
                     "all day"
                     (string-append (calendar--prop e 'starts) "-" (calendar--prop e 'ends)))
                 "  " (or (calendar--prop e 'summary) "(no title)")
                 "  - " (or (calendar--prop e 'calendar) "")))

(define (calendar--event-link e)
  (let ((url (calendar--prop e 'url))
        (loc (calendar--prop e 'location)))
    (cond (url url)
          ((and (string? loc) (string-prefix? "http" loc)) loc)
          (else #f))))

(define (calendar--view-row e line today? now)
  (let* ((all-day (calendar--prop e 'all_day))
         (starts (calendar--prop e 'starts))
         (ends (calendar--prop e 'ends))
         (url (calendar--event-link e))
         (timed (and today? (not all-day) starts ends))
         (current (and timed (not (< now starts)) (< now ends)))
         (past (and timed (not (< now ends)))))
    (component 'ui/row
      (list 'tag "calendar-event"
            'class (string-append "cal-row" (cond (current " cal-now") (past " cal-past") (else "")))
            'click (string-append "e-" (number->string line))
            'lines (list line line) 'mark "current"
            'segs (append
                   (list (list "cal-time" (if all-day "all day" (string-append starts " - " ends)))
                         (list "cal-title" (or (calendar--prop e 'summary) "(no title)")))
                   (if url
                       (list (list "cal-link" (if (string-contains? url "meet.google") "meet" "link")))
                       '())
                   (list (list "cal-cal" (or (calendar--prop e 'calendar) ""))))))))

(define *calendar-view-keys*
  '(("n p" "event") ("RET" "open link") ("TAB" "fold day")
    ("[ ]" "earlier, later") ("." "today") ("d w m" "day, week, month")
    ("g" "refresh") ("q" "quit")))

(define (calendar--view-render! buf)
  (let* ((range (calendar--view-range buf))
         (from (car range))
         (n (car (cdr range)))
         (rows (buffer-local buf 'calendar-rows))
         (loading (buffer-local buf 'calendar-loading))
         (closed (or (buffer-local buf 'calendar-closed) '()))
         (today (calendar--now-day))
         (now (format-time (current-time) "%H:%M"))
         (header (string-append (calendar--view-title buf)
                                (if loading "  (loading)" ""))))
    (let loop ((i 0) (text (string-append header "\n")) (line 2)
               (index '()) (dlines '()) (folds '()) (blocks '()))
      (if (< i n)
          (let* ((day (calendar--day-add from i))
                 (es (if rows (filter (lambda (e) (equal? (calendar--prop e 'day) day)) rows) '()))
                 (today? (equal? day today))
                 (label (calendar--day-label day))
                 (closed? (member day closed))
                 (dstart (string-byte-length text))
                 (r (let eloop ((es2 es) (t2 (string-append text label "\n"))
                                (l2 (+ line 1)) (ix index) (out '()))
                      (if (null? es2)
                          (list t2 l2 ix (reverse out))
                          (let ((e (car es2)))
                            (eloop (cdr es2)
                                   (string-append t2 (calendar--view-line e) "\n")
                                   (+ l2 1)
                                   (cons (list l2 e) ix)
                                   (cons (calendar--view-row e l2 today? now) out))))))
                 (t3 (list-ref r 0))
                 (l3 (list-ref r 1))
                 (eol (+ dstart (string-byte-length label)))
                 (dend (string-byte-length t3)))
            (loop (+ i 1) t3 l3 (list-ref r 2)
                  (cons (list line day) dlines)
                  (if (and closed? (pair? es)) (cons (list eol (- dend 1)) folds) folds)
                  (cons (component 'ui/card
                          (list 'tag "calendar-day"
                                'class (if today? "cal-day cal-today" "cal-day")
                                'title label
                                'badge (cond ((not rows) "")
                                             ((null? es) (if today? "free, today" "free"))
                                             (else (string-append (number->string (length es))
                                                                  (if today? ", today" ""))))
                                'open? (not closed?)
                                'click (string-append "d-" day)
                                'lines (list line (- l3 1)) 'mark "current"
                                'body (list-ref r 3)))
                        blocks)))
          (let ((p (buffer-point buf)))
            (buffer-set-read-only! buf #f)
            (buffer-delete-range! buf 0 (buffer-size buf))
            (buffer-append! buf text)
            (buffer-set-read-only! buf #t)
            (buffer-goto! buf (min p (buffer-size buf)))
            (buffer-set-local! buf 'calendar-index (reverse index))
            (buffer-set-local! buf 'calendar-day-lines (reverse dlines))
            (buffer-set-local! buf 'render-root (list 'tag "calendar-view"))
            (buffer-set-local! buf 'render-blocks
              (cons (list 'tag "c-headerline" 'class "cal-header" 'text header)
                    (reverse blocks)))
            (buffer-set-local! buf 'footer-line-blocks
              (list (component 'ui/keys-bar (list 'main *calendar-view-keys*))))
            (fold-set! buf 'calendar (reverse folds)))))))

(define (calendar--view-fetch! buf)
  (let* ((range (calendar--view-range buf))
         (from (car range))
         (to (calendar--day-add from (- (car (cdr range)) 1)))
         (key (string-append from ".." to))
         (hit (assoc key *calendar-view-cache*)))
    (if hit
        (begin (buffer-set-local! buf 'calendar-rows (cdr hit))
               (buffer-set-local! buf 'calendar-loading #f)
               (calendar--view-render! buf))
        (begin
          (buffer-set-local! buf 'calendar-rows #f)
          (buffer-set-local! buf 'calendar-loading key)
          (calendar--view-render! buf)
          (task-run! (lambda () (calendar-events from to))
                     (lambda (ok? rows)
                       (let ((rows (if (and ok? (pair? rows)) rows '())))
                         (when ok?
                           (set! *calendar-view-cache* (cons (cons key rows) *calendar-view-cache*)))
                         (when (and (buffer-exists? buf)
                                    (equal? (buffer-local buf 'calendar-loading) key))
                           (buffer-set-local! buf 'calendar-rows rows)
                           (buffer-set-local! buf 'calendar-loading #f)
                           (calendar--view-render! buf)
                           (when (not ok?) (message "calendar: the fetch failed")))))
                     60000)))))

(define (calendar--view-line-at buf pos)
  (let loop ((ls (split-lines (buffer-text buf))) (n 1) (at 0))
    (cond ((null? ls) n)
          ((> (+ at (string-byte-length (car ls))) pos) n)
          (else (loop (cdr ls) (+ n 1) (+ at (string-byte-length (car ls)) 1))))))

(define (calendar--view-event-at buf)
  (let ((hit (assoc (calendar--view-line-at buf (buffer-point buf))
                    (or (buffer-local buf 'calendar-index) '()))))
    (and hit (car (cdr hit)))))

(define (calendar--view-day-at buf)
  (let ((here (calendar--view-line-at buf (buffer-point buf))))
    (fold (lambda (acc d) (if (<= (car d) here) (car (cdr d)) acc))
          #f (or (buffer-local buf 'calendar-day-lines) '()))))

(define (calendar--view-step! dir)
  (let* ((buf (current-buffer))
         (here (calendar--view-line-at buf (buffer-point buf)))
         (lines (map car (or (buffer-local buf 'calendar-index) '())))
         (cand (filter (lambda (l) (if (> dir 0) (> l here) (< l here))) lines))
         (best (fold (lambda (acc l)
                       (if (or (not acc) (if (> dir 0) (< l acc) (> l acc))) l acc))
                     #f cand)))
    (if best
        (goto-char! (line-start-position best))
        (message "no more events"))))

(define (calendar--view-open! e)
  (let ((url (and e (calendar--event-link e))))
    (if url (tab-open url) (message "calendar: this event has no link"))))

(define (calendar--view-toggle! buf day)
  (let ((closed (or (buffer-local buf 'calendar-closed) '())))
    (buffer-set-local! buf 'calendar-closed
      (if (member day closed)
          (filter (lambda (d) (not (equal? d day))) closed)
          (cons day closed)))
    (calendar--view-render! buf)))

(define (calendar--view-move! buf start)
  (buffer-set-local! buf 'calendar-start start)
  (calendar--view-fetch! buf))

(define-command "calendar-view-next" "Move to the next event"
  (lambda () (calendar--view-step! 1)))

(define-command "calendar-view-previous" "Move to the previous event"
  (lambda () (calendar--view-step! -1)))

(define-command "calendar-view-open" "Open the event's meeting link in the browser"
  (lambda () (calendar--view-open! (calendar--view-event-at (current-buffer)))))

(define-command "calendar-view-toggle-day" "Fold or unfold the day at point"
  (lambda ()
    (let* ((buf (current-buffer)) (day (calendar--view-day-at buf)))
      (when day (calendar--view-toggle! buf day)))))

(define-command "calendar-view-later" "Show the next day, week or month"
  (lambda () (calendar--view-step-period! (current-buffer) 1)))

(define-command "calendar-view-earlier" "Show the previous day, week or month"
  (lambda () (calendar--view-step-period! (current-buffer) -1)))

(define-command "calendar-view-day" "Show one day"
  (lambda () (calendar--view-set-span! (current-buffer) "day")))

(define-command "calendar-view-week" "Show the week"
  (lambda () (calendar--view-set-span! (current-buffer) "week")))

(define-command "calendar-view-month" "Show the month"
  (lambda () (calendar--view-set-span! (current-buffer) "month")))

(define-command "calendar-view-today" "Return the view to today"
  (lambda () (calendar--view-move! (current-buffer) (calendar--now-day))))

(define-command "calendar-view-refresh" "Fetch the days on screen again"
  (lambda ()
    (set! *calendar-view-cache* '())
    (calendar--view-fetch! (current-buffer))))

(add-hook! (list 'block-click 'calendar)
  (lambda (buf id)
    (and (buffer-local buf 'calendar-day-lines)
         (cond ((string-prefix? "d-" id)
                (calendar--view-toggle! buf (substring id 2 (string-length id)))
                #t)
               ((string-prefix? "e-" id)
                (let* ((l (string->number (substring id 2 (string-length id))))
                       (hit (and l (assoc l (or (buffer-local buf 'calendar-index) '())))))
                  (when hit (calendar--view-open! (car (cdr hit)))))
                #t)
               (else #f)))))

(mode-parent! "calendar-mode" "special-mode")
(define-mode "calendar-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (local-remap! "next-line" "calendar-view-next")
      (local-remap! "previous-line" "calendar-view-previous")
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'desktop-skip-locals
        '(render-root render-blocks footer-line-blocks calendar-index calendar-day-lines
          calendar-rows calendar-loading))
      (buffer-set-local! buf 'render-mode "blocks")
      (calendar--view-fetch! buf))))

(mode-keys! "calendar-mode"
  '(("n" "calendar-view-next")
    ("p" "calendar-view-previous")
    ("RET" "calendar-view-open")
    ("TAB" "calendar-view-toggle-day")
    ("]" "calendar-view-later")
    ("[" "calendar-view-earlier")
    ("." "calendar-view-today")
    ("d" "calendar-view-day")
    ("w" "calendar-view-week")
    ("m" "calendar-view-month")
    ("g" "calendar-view-refresh")
    ("q" "quit-window")))

(mode-doc! "calendar-mode"
  "The calendar, a page of days at a time, as day cards. Only the days on screen are fetched, in the background, and a page seen once comes back from a cache. n and p step over events, RET opens the meeting link, TAB folds a day. d, w and m show a day, a week or a month; ] and [ move by one of them, and . returns to today. g fetches again.")

(define-style! 'calendar "
.cal-header { font-family: var(--font-serif); font-size: 20px; padding: 8px 2px 12px; }
.cal-day { margin: 0 0 10px; }
.cal-day .c-fold-head { font-family: var(--font-sans); font-weight: 600; }
.cal-day .c-fold-badge { color: var(--dim-fg); font-weight: 400; font-size: 11px; margin-left: auto; }
.cal-today .c-fold-head { border-left: 3px solid #a03020; }
.cal-row { display: flex; align-items: baseline; gap: 12px; }
.cal-time { font-family: var(--font-mono); color: var(--dim-fg); min-width: 13ch; }
.cal-title { flex: 1; font-family: var(--font-sans); }
.cal-link { font-family: var(--font-mono); font-size: 10px; padding: 0 8px; border: 1px solid var(--border-bg); color: var(--dim-fg); }
.cal-cal { font-family: var(--font-mono); font-size: 11px; color: var(--dim-fg); }
.cal-past .cal-title, .cal-past .cal-time { color: var(--dim-fg); }
.cal-now .cal-time { color: #a03020; font-weight: 600; }
.cal-now .cal-title { font-weight: 600; }
")


(define (calendar--plus-minutes stamp minutes)
  (string-trim
   (shell-command->string
    (string-append "date -j -v+" (number->string minutes) "M -f '%Y-%m-%d %H:%M' "
                   (sh-quote stamp) " '+%Y-%m-%d %H:%M'")
    (getenv "HOME"))))

(define (calendar--minutes text)
  (let ((n (if (or (not text) (equal? text "")) 60 (string->number text))))
    (if (number? n) n 60)))

(define (calendar--writable-titles)
  (map (lambda (row) (calendar--prop row 'title))
       (filter (lambda (row) (calendar--prop row 'writable)) (calendar-calendars))))

(define (calendar--sync-and-report)
  (let ((done (calendar-sync!)))
    (if done
        (message (string-append "calendar: "
                                (number->string (calendar--prop done 'events))
                                " events to " (calendar--prop done 'to)))
        #f)
    done))

(define-command "calendar" "Show the calendar in the other window"
  (lambda ()
    (buffer-create *calendar-view-buffer*)
    (with-current-buffer *calendar-view-buffer* (lambda () (set-mode! "calendar-mode")))
    (display-buffer-other-window! *calendar-view-buffer*)))

(define-command "calendar-sync" "Refresh the calendar file from every configured source"
  (lambda () (calendar--sync-and-report)))

(define-command "calendar-add-event" "Add one event to a calendar"
  (lambda ()
    (read-string "Title: "
      (lambda (title)
        (if (or (not title) (equal? title ""))
            (message "calendar: cancelled")
            (read-string "Start (YYYY-MM-DD HH:MM): "
              (lambda (start)
                (if (or (not start) (equal? start ""))
                    (message "calendar: cancelled")
                    (read-string "Minutes: "
                      (lambda (mins)
                        (completing-read "Calendar: " (calendar--writable-titles)
                          (lambda (cal)
                            (if (not cal)
                                (message "calendar: cancelled")
                                (let ((made (calendar-add!
                                             'title title
                                             'start start
                                             'end (calendar--plus-minutes
                                                   start (calendar--minutes mins))
                                             'calendar cal)))
                                  (if (not made)
                                      (message "calendar: the event was not created")
                                      (begin
                                        (calendar-sync!)
                                        (message (string-append
                                                  "calendar: added \"" title "\" to "
                                                  cal " at "
                                                  (calendar--prop made 'starts_at)))))))))
                        )
                      'initial "60")))
              'initial (string-append (calendar--today) " "))))))) 

(define-command "calendar-agent-status" "Report the calendar agent: loaded, last drain, pending"
  (lambda ()
    (let ((s (calendar-agent-status)))
      (message (string-append "calendar agent " (calendar--prop s 'agent)
                              ", last drain " (calendar--prop s 'last-drain)
                              ", " (calendar--prop s 'pending) " pending")))))

(define-command "calendar-agent-install" "Install and start the calendar agent in the GUI session"
  (lambda ()
    (let ((s (calendar-agent-install!)))
      (message (string-append "calendar agent " (calendar--prop s 'agent))))))

(define-command "calendar-reload-config" "Read ~/.compos/calendar.scm again"
  (lambda ()
    (let ((sources (calendar-config-load!)))
      (message (string-append "calendar: "
                              (number->string (length sources))
                              " sources from " (calendar-config-path))))))

;; The sources are read at load, so a reload or a restart never leaves the
;; verbs with an empty source list.
(calendar-config-load!)
