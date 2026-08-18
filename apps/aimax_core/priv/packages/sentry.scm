;;; sentry.scm --- read production errors without leaving the editor.
;;;
;;; The package reads Sentry only. It does not resolve, assign, or delete
;;; issues. The token comes from the environment or one named Doppler config.
;;; curl reads it from a temporary config file, never from the command line.
;;;
;;; M-x sentry opens unresolved production issues. RET shows a safe summary.
;;; The summary and event list omit user data, payloads, breadcrumbs, and stacks.

(domain! 'sentry)
(effects! '(write))

(defgroup 'sentry "Sentry: read production errors in the editor.")

(defcustom 'sentry-base-url "https://sentry.io"
  "The Sentry API base URL." 'group 'sentry)

(defcustom 'sentry-org "svs-recruiting"
  "The default Sentry organization slug." 'group 'sentry)

(defcustom 'sentry-project "ats-ash"
  "The default Sentry project slug." 'group 'sentry)

(defcustom 'sentry-environment "prod"
  "The default Sentry environment." 'group 'sentry)

(defcustom 'sentry-time-range "24h"
  "The default Sentry statistics period." 'group 'sentry)

(defcustom 'sentry-query "is:unresolved"
  "The default Sentry issue search." 'group 'sentry)

(defcustom 'sentry-limit 20
  "The maximum rows one Sentry request returns." 'group 'sentry)

(defcustom 'sentry-timeout 30
  "Seconds to wait for one Sentry request." 'group 'sentry)

(defcustom 'sentry-curl-program "curl"
  "The curl executable for Sentry requests." 'group 'sentry)

(defcustom 'sentry-doppler-project "ats_ash"
  "The Doppler project that holds SENTRY_AUTH_TOKEN." 'group 'sentry)

(defcustom 'sentry-doppler-config "prd"
  "The Doppler config that holds SENTRY_AUTH_TOKEN." 'group 'sentry)

;;; --- small helpers ------------------------------------------------------------

(define (sentry--get pl key)
  (if (pair? pl) (plist-get pl key) #f))

(define (sentry--text value)
  (cond ((string? value) value)
        ((number? value) (number->string value))
        ((symbol? value) (symbol->string value))
        (else "")))

(define (sentry--replace text from to)
  (string-join (string-split text from) to))

(define (sentry--shell-quote text)
  (string-append "'" (sentry--replace text "'" "'\\''") "'"))

(define (sentry--config-escape text)
  (sentry--replace (sentry--replace (sentry--text text) "\\" "\\\\") "\"" "\\\""))

(define (sentry--truncate text width)
  (let ((value (sentry--text text)))
    (if (> (string-length value) width)
        (string-append (substring value 0 (- width 1)) "…")
        value)))

;; Sentry titles and culprit strings can contain addresses. The package shows
;; neither event payloads nor user objects, and masks common address forms here.
(define (sentry--redact text)
  (let* ((value (sentry--text text))
         (value (re-replace-all
                  "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
                  value "[redacted-email]")))
    (re-replace-all
      "\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b"
      value "[redacted-ip]")))

(define (sentry--take rows count)
  (if (or (null? rows) (< count 1))
      '()
      (cons (car rows) (sentry--take (cdr rows) (- count 1)))))

(define (sentry--limit value)
  (let ((n (if (number? value) value sentry-limit)))
    (max 1 (min 50 n))))

(define (sentry--url path params)
  (string-append
    sentry-base-url path
    (if (null? params)
        ""
        (string-append
          "?"
          (string-join
            (map (lambda (pair)
                   (string-append (url-encode (car pair)) "="
                                  (url-encode (sentry--text (cadr pair)))))
                 params)
            "&")))))

(define (sentry--project-path tail)
  (string-append "/api/0/projects/" (url-encode sentry-org) "/"
                 (url-encode sentry-project) "/" tail))

(define (sentry--org-path tail)
  (string-append "/api/0/organizations/" (url-encode sentry-org) "/" tail))

;;; --- credentials and wire -----------------------------------------------------

(define *sentry--seq* 0)

(define (sentry--tmp-path)
  (set! *sentry--seq* (+ *sentry--seq* 1))
  (let ((dir (string-append (aimax-home) "/tmp")))
    (make-directory! dir)
    (string-append dir "/sentry-" (number->string (current-time)) "-"
                   (number->string *sentry--seq*) ".conf")))

;; Resolve the token only when a request leaves. Do not cache it in this package.
(define (sentry--token)
  (or (getenv "SENTRY_AUTH_TOKEN")
      (and (boundp 'doppler-secret-value)
           (doppler-secret-value sentry-doppler-project sentry-doppler-config
                                 "SENTRY_AUTH_TOKEN"))
      #f))

(define (sentry--curl-config url token)
  (string-append
    "url = \"" (sentry--config-escape url) "\"\n"
    "request = \"GET\"\n"
    "header = \"Authorization: Bearer " (sentry--config-escape token) "\"\n"
    "header = \"Accept: application/json\"\n"
    "max-time = " (number->string sentry-timeout) "\n"
    "silent\nshow-error\nwrite-out = \"\\n%{http_code}\"\n"))

;; Return curl output with its final HTTP status line. Tests replace this seam.
(define (sentry--curl url)
  (let ((token (sentry--token)))
    (if (not token)
        "SENTRY_AUTH_TOKEN is not configured\n000"
        (let ((path (sentry--tmp-path)))
          (write-file! path (sentry--curl-config url token))
          (let ((out (shell-command->string
                       (string-append sentry-curl-program " --config "
                                      (sentry--shell-quote path)))))
            (delete-file! path)
            out)))))

(define *sentry-transport* sentry--curl)

(define (sentry--split-status output)
  (let* ((lines (string-split output "\n"))
         (last (car (reverse lines)))
         (status (string->number last)))
    (if (number? status)
        (list status (string-join (reverse (cdr (reverse lines))) "\n"))
        (list 0 output))))

(define (sentry--error text)
  (list 'errors (list (list 'message text))))

(define (sentry--error? reply)
  (and (pair? reply) (equal? (car reply) 'errors)))

(define (sentry--error-message reply)
  (if (not (sentry--error? reply))
      #f
      (or (sentry--get (car (sentry--get reply 'errors)) 'message)
          "Sentry request failed")))

;; Parse every result into JSON or one stable error plist. Do not include an
;; HTTP response body in an error because it can hold deployment details.
(define (sentry--request url)
  (let* ((wire (*sentry-transport* url))
         (parts (sentry--split-status wire))
         (status (car parts))
         (body (cadr parts)))
    (cond ((= status 0)
           (sentry--error (string-trim body)))
          ((or (< status 200) (> status 299))
           (sentry--error (string-append "Sentry returned HTTP "
                                         (number->string status))))
          (else
            (let ((reply (json-parse body)))
              (if (equal? reply #f)
                  (sentry--error "Sentry returned invalid JSON")
                  reply))))))

;;; --- read-only API ------------------------------------------------------------

;; Reduce API objects at the boundary. Callers cannot accidentally print user
;; objects, request payloads, breadcrumbs, stack traces, or issue metadata.
(define (sentry--safe-issue issue)
  (list 'id (sentry--get issue 'id)
        'shortId (sentry--get issue 'shortId)
        'title (sentry--redact (sentry--get issue 'title))
        'status (sentry--get issue 'status)
        'level (sentry--get issue 'level)
        'culprit (sentry--redact (sentry--get issue 'culprit))
        'count (sentry--get issue 'count)
        'userCount (sentry--get issue 'userCount)
        'firstSeen (sentry--get issue 'firstSeen)
        'lastSeen (sentry--get issue 'lastSeen)
        'permalink (sentry--get issue 'permalink)))

(define (sentry--safe-event event)
  (list 'eventID (sentry--get event 'eventID)
        'dateCreated (sentry--get event 'dateCreated)
        'environment (sentry--get event 'environment)
        'platform (sentry--get event 'platform)
        'culprit (sentry--redact (sentry--get event 'culprit))))

(define (sentry-list-issues &optional query environment time-range limit)
  (let* ((count (sentry--limit limit))
         (reply
           (sentry--request
             (sentry--url
               (sentry--project-path "issues/")
               (list (list "environment" (or environment sentry-environment))
                     (list "statsPeriod" (or time-range sentry-time-range))
                     (list "query" (or query sentry-query))
                     (list "per_page" count))))))
    (if (sentry--error? reply)
        reply
        (map sentry--safe-issue (sentry--take reply count)))))

(define (sentry-issue-detail issue-id)
  (let ((reply
          (sentry--request
            (sentry--url
              (sentry--org-path
                (string-append "issues/" (url-encode (sentry--text issue-id)) "/"))
              '()))))
    (if (sentry--error? reply) reply (sentry--safe-issue reply))))

(define (sentry-issue-events issue-id &optional environment time-range limit)
  (let* ((count (sentry--limit limit))
         (reply
           (sentry--request
             (sentry--url
               (sentry--org-path
                 (string-append "issues/" (url-encode (sentry--text issue-id))
                                "/events/"))
               (list (list "environment" (or environment sentry-environment))
                     (list "statsPeriod" (or time-range sentry-time-range))
                     (list "per_page" count))))))
    (if (sentry--error? reply)
        reply
        (map sentry--safe-event (sentry--take reply count)))))

(define (sentry-event-detail event-id)
  (let ((reply
          (sentry--request
            (sentry--url
              (sentry--project-path
                (string-append "events/" (url-encode (sentry--text event-id)) "/"))
              '()))))
    (if (sentry--error? reply) reply (sentry--safe-event reply))))

;;; --- safe views ---------------------------------------------------------------

(define *sentry-buffer* "*Sentry issues*")
(define *sentry-group* "sentry")

;; The list founds one stable workspace. Its companion chat and every child
;; view use the same tag, including when mode setup runs after desktop restore.
(define (sentry--join-group! buf)
  (buffer-set-local! buf 'group *sentry-group*)
  buf)

(define (sentry--issue-cells buf issue)
  (let ((level (sentry--get issue 'level)))
    (list
      (list (sentry--get issue 'shortId) "accent")
      (list level (cond ((equal? level "error") "alert")
                        ((equal? level "warning") "warn")
                        (else "dim")))
      (list (sentry--get issue 'count) "dim")
      (list (sentry--get issue 'lastSeen) "dim")
      (sentry--redact (sentry--get issue 'title)))))

(define (sentry--issue-meta buf)
  (string-append
    (number->string (length (list-entries buf))) " unresolved · "
    sentry-org "/" sentry-project " · " sentry-environment " · " sentry-time-range))

(define (sentry--issue-rows buf)
  (sentry--join-group! buf)
  (let ((reply (sentry-list-issues)))
    (if (sentry--error? reply)
        (begin (message (sentry--error-message reply)) '())
        reply)))

(define (sentry--safe-field label value)
  (let ((text (sentry--redact value)))
    (if (equal? text "") "" (string-append label ": " text "\n"))))

(define (sentry--issue-text issue)
  (string-append
    (sentry--safe-field "Issue" (sentry--get issue 'shortId))
    (sentry--safe-field "Title" (sentry--get issue 'title))
    (sentry--safe-field "Status" (sentry--get issue 'status))
    (sentry--safe-field "Level" (sentry--get issue 'level))
    (sentry--safe-field "Culprit" (sentry--get issue 'culprit))
    (sentry--safe-field "Events" (sentry--get issue 'count))
    (sentry--safe-field "Users" (sentry--get issue 'userCount))
    (sentry--safe-field "First seen" (sentry--get issue 'firstSeen))
    (sentry--safe-field "Last seen" (sentry--get issue 'lastSeen))
    (sentry--safe-field "Sentry" (sentry--get issue 'permalink))))

(define (sentry--replace-buffer! buf text)
  (buffer-create buf)
  (buffer-set-read-only! buf #f)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-append! buf text)
  (buffer-set-read-only! buf #t))

(define (sentry--detail-buffer issue-id)
  (string-append "*Sentry issue: " (sentry--text issue-id) "*"))

(define (sentry--render-detail! buf issue-id)
  (let ((issue (sentry-issue-detail issue-id)))
    (sentry--replace-buffer!
      buf
      (if (sentry--error? issue)
          (string-append (sentry--error-message issue) "\n")
          (string-append (sentry--issue-text issue)
                         "\nThis view omits user data, payloads, breadcrumbs, and stack traces.\n")))))

(define (sentry--detail-setup! buf)
  (sentry--join-group! buf)
  (local-set-key* buf "g" "sentry-detail-refresh")
  (local-set-key* buf "e" "sentry-events")
  (local-set-key* buf "q" "quit-window")
  (let ((issue-id (buffer-local buf 'sentry-issue-id)))
    (when (and issue-id (= (buffer-size buf) 0))
      (sentry--render-detail! buf issue-id))))

(define (sentry--event-line event)
  (string-append
    (string-pad-right (sentry--truncate (sentry--get event 'dateCreated) 24) 24) "  "
    (string-pad-right (sentry--truncate (sentry--get event 'environment) 10) 10) "  "
    (string-pad-right (sentry--truncate (sentry--get event 'platform) 12) 12) "  "
    (sentry--truncate (sentry--get event 'eventID) 40)))

(define (sentry--events-text events)
  (if (null? events)
      "No events matched.\n"
      (fold (lambda (text event)
              (string-append text (sentry--event-line event) "\n"))
            "Time                      Environment  Platform      Event ID\n\n"
            events)))

(define (sentry--render-events! buf issue-id)
  (let ((events (sentry-issue-events issue-id)))
    (sentry--replace-buffer!
      buf
      (if (sentry--error? events)
          (string-append (sentry--error-message events) "\n")
          (string-append (sentry--events-text events)
                         "\nThis view omits event messages, user data, payloads, breadcrumbs, and stacks.\n")))))

(define (sentry--events-setup! buf)
  (sentry--join-group! buf)
  (local-set-key* buf "g" "sentry-events-refresh")
  (local-set-key* buf "q" "quit-window")
  (let ((issue-id (buffer-local buf 'sentry-issue-id)))
    (when issue-id (sentry--render-events! buf issue-id))))

;;; --- modes and commands -------------------------------------------------------

(domain! 'sentry)
(effects! '(write external))

(mode-icon! "sentry-detail-mode" "")

(define-mode "sentry-detail-mode"
  (lambda () (sentry--detail-setup! (current-buffer))))

(mode-doc! "sentry-detail-mode"
  "A safe summary for one Sentry issue. `e` lists events. `g` refreshes the summary.")

(mode-icon! "sentry-events-mode" "")

(define-mode "sentry-events-mode"
  (lambda () (sentry--events-setup! (current-buffer))))

(mode-doc! "sentry-events-mode"
  "Safe event identifiers for one Sentry issue. `g` refreshes the list.")

(define-command "sentry-open" "Show a safe summary for the Sentry issue on this row"
  (lambda ()
    (let ((issue (list-current *sentry-buffer*)))
      (when issue
        (let* ((issue-id (sentry--get issue 'id))
               (buf (sentry--detail-buffer issue-id)))
          (buffer-create buf)
          (buffer-set-local! buf 'sentry-issue-id issue-id)
          (display-buffer-other-window! buf)
          (with-current-buffer buf (lambda () (set-mode! "sentry-detail-mode"))))))))

(define-command "sentry-refresh" "Refresh the Sentry issue list"
  (lambda () (list-refresh! *sentry-buffer*)))

(define-command "sentry-detail-refresh" "Refresh this Sentry issue summary"
  (lambda ()
    (let ((issue-id (buffer-local (current-buffer) 'sentry-issue-id)))
      (when issue-id (sentry--render-detail! (current-buffer) issue-id)))))

(define-command "sentry-events" "List safe event identifiers for this Sentry issue"
  (lambda ()
    (let ((issue-id (buffer-local (current-buffer) 'sentry-issue-id)))
      (when issue-id
        (let ((buf (string-append "*Sentry events: " (sentry--text issue-id) "*")))
          (buffer-create buf)
          (buffer-set-local! buf 'sentry-issue-id issue-id)
          (display-buffer-other-window! buf)
          (with-current-buffer buf (lambda () (set-mode! "sentry-events-mode"))))))))

(define-command "sentry-events-refresh" "Refresh this Sentry event list"
  (lambda ()
    (let ((issue-id (buffer-local (current-buffer) 'sentry-issue-id)))
      (when issue-id (sentry--render-events! (current-buffer) issue-id)))))

(mode-icon! "sentry-mode" "")

(define-list-mode! "sentry-mode"
  (list
    'doc (string-append
           "Unresolved Sentry issues for the configured project and environment. "
           "RET opens a safe summary. `g` refreshes the list.")
    'buffer *sentry-buffer*
    'rows sentry--issue-rows
    'columns (lambda (buf)
               (list (list "issue" 13) (list "level" 8)
                     (list "events" 7 'right) (list "last seen" 20)
                     (list "title" #f)))
    'cells sentry--issue-cells
    'title (lambda (buf) "Sentry issues")
    'meta sentry--issue-meta
    'total (lambda (buf) (length (list-entries buf)))
    'no-marks #t
    'footer (lambda (buf)
              '(("RET" "detail") ("/" "filter") ("g" "refresh") ("q" "quit")))
    'key (lambda (buf issue) (sentry--get issue 'id))
    'keys '(("RET" "sentry-open") ("g" "sentry-refresh") ("q" "quit-window"))))

(define-command "sentry" "List unresolved production issues from Sentry"
  (lambda () (list-mode-show! "sentry-mode")))

;;; --- catalog ------------------------------------------------------------------

(category! 'sentry)
(effects! '(read external))

(public! 'sentry-list-issues
  "(sentry-list-issues [QUERY] [ENVIRONMENT] [TIME-RANGE] [LIMIT]) — list Sentry issues; defaults are unresolved production issues from the last 24 hours")
(public! 'sentry-issue-detail
  "(sentry-issue-detail ISSUE-ID) — read one Sentry issue")
(public! 'sentry-issue-events
  "(sentry-issue-events ISSUE-ID [ENVIRONMENT] [TIME-RANGE] [LIMIT]) — list events for one Sentry issue")
(public! 'sentry-event-detail
  "(sentry-event-detail EVENT-ID) — read safe identifiers for one Sentry event")

(effects! '(write external))
(public! 'sentry
  "M-x sentry — list unresolved production issues and open safe summaries")

(defrecipe! "inspect unresolved production errors"
  "(sentry)"
  '())
