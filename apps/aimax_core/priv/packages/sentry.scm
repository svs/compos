;;; sentry.scm --- inspect and manage production errors in the editor.
;;;
;;; The package reads Sentry issues and can resolve one after confirmation.
;;; The token comes from the environment or one named Doppler config.
;;; curl reads it from a temporary config file, never from the command line.
;;;
;;; M-x sentry opens unresolved production issues. RET shows a structured detail view.
;;; The issue view keeps complete raw JSON behind a collapsed disclosure.

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

(define (sentry--curl-write-config url token body)
  (string-append
    "url = \"" (sentry--config-escape url) "\"\n"
    "request = \"PUT\"\n"
    "header = \"Authorization: Bearer " (sentry--config-escape token) "\"\n"
    "header = \"Accept: application/json\"\n"
    "header = \"Content-Type: application/json\"\n"
    "data = \"" (sentry--config-escape body) "\"\n"
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

(define (sentry--curl-write url body)
  (let ((token (sentry--token)))
    (if (not token)
        "SENTRY_AUTH_TOKEN is not configured\n000"
        (let ((path (sentry--tmp-path)))
          (write-file! path (sentry--curl-write-config url token body))
          (let ((out (shell-command->string
                       (string-append sentry-curl-program " --config "
                                      (sentry--shell-quote path)))))
            (delete-file! path)
            out)))))

(define *sentry-transport* sentry--curl)
(define *sentry-write-transport* sentry--curl-write)

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

(define (sentry--request-write url payload)
  (let* ((wire (*sentry-write-transport* url (json-encode payload)))
         (parts (sentry--split-status wire))
         (status (car parts))
         (body (cadr parts)))
    (cond ((= status 0)
           (sentry--error (string-trim body)))
          ((or (< status 200) (> status 299))
           (sentry--error (string-append "Sentry returned HTTP "
                                         (number->string status))))
          ((equal? (string-trim body) "")
           (list 'status "resolved"))
          (else
            (let ((reply (json-parse body)))
              (if (equal? reply #f)
                  (sentry--error "Sentry returned invalid JSON")
                  reply))))))

;;; --- API ----------------------------------------------------------------------

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
    (if (sentry--error? reply) reply reply)))

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
    (if (sentry--error? reply) reply reply)))

(define (sentry-resolve-issue issue-id)
  (sentry--request-write
    (sentry--url
      (sentry--org-path
        (string-append "issues/"
                       (url-encode (sentry--text issue-id))
                       "/"))
      '())
    (list 'status "resolved")))

;;; --- views --------------------------------------------------------------------

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

(define (sentry--pretty-json value)
  (let ((text (shell-command->string
                (string-append "printf %s "
                               (sentry--shell-quote (json-encode value))
                               " | jq .")
                (default-directory))))
    (if (equal? (string-trim text) "")
        (json-encode value)
        text)))

(define (sentry--html-escape text)
  (let* ((value (sentry--text text))
         (value (re-replace-all "&" value "&amp;"))
         (value (re-replace-all "<" value "&lt;"))
         (value (re-replace-all ">" value "&gt;")))
    (re-replace-all "\"" value "&quot;")))

(define (sentry--issue-title issue)
  (let* ((title (string-trim (sentry--text (sentry--get issue 'title))))
         (metadata (sentry--get issue 'metadata))
         (kind (string-trim (sentry--text (sentry--get metadata 'type)))))
    (cond ((not (equal? title "")) (sentry--redact title))
          ((not (equal? kind "")) kind)
          (else (sentry--text (sentry--get issue 'shortId))))))

(define (sentry--summary-pairs issue)
  (list
    (list "Status" (sentry--text (sentry--get issue 'status)))
    (list "Priority" (sentry--text (sentry--get issue 'priority)))
    (list "Level" (sentry--text (sentry--get issue 'level)))
    (list "Events" (sentry--text (sentry--get issue 'count)))
    (list "Users" (sentry--text (sentry--get issue 'userCount)))
    (list "First seen" (sentry--text (sentry--get issue 'firstSeen)))
    (list "Last seen" (sentry--text (sentry--get issue 'lastSeen)))
    (list "Platform" (sentry--text (sentry--get issue 'platform)))))

(define (sentry--location-pairs issue)
  (let ((metadata (sentry--get issue 'metadata)))
    (list
      (list "Culprit" (sentry--text (sentry--get issue 'culprit)))
      (list "Exception" (sentry--text (sentry--get metadata 'type)))
      (list "Function" (sentry--text (sentry--get metadata 'function)))
      (list "File" (sentry--text (sentry--get metadata 'filename)))
      (list "Issue URL" (sentry--text (sentry--get issue 'permalink))))))

(define (sentry--tag-lines issue)
  (map (lambda (tag)
         (list 'tag "div" 'class "sentry-tag"
               'segs (list
                       (list "c-kv-key" (sentry--text (sentry--get tag 'name)))
                       (list "c-kv-value"
                             (string-append
                               "  "
                               (sentry--text (sentry--get tag 'totalValues))
                               " values")))))
       (or (sentry--get issue 'tags) '())))

(define sentry--detail-actions
  '(("sentry:ask" "Ask agent" "a")
    ("sentry:open" "Open in Sentry" "o")
    ("sentry:resolve" "Resolve" "R")
    ("sentry:events" "Events" "e")
    ("sentry:refresh" "Refresh" "g")))

(define (sentry--issue-blocks issue raw-open?)
  (let* ((metadata (sentry--get issue 'metadata))
         (exception (sentry--text (sentry--get metadata 'value)))
         (status (sentry--text (sentry--get issue 'status)))
         (priority (sentry--text (sentry--get issue 'priority))))
    (list
      (component 'ui/section
        (list 'title
          (string-append
            (sentry--text (sentry--get issue 'shortId))
            " — "
            (sentry--issue-title issue))))
      (list 'tag "div" 'class "sentry-state"
            'children
            (list
              (component 'ui/badge
                (list 'text status
                      'class (if (equal? status "resolved") "success" "warn")))
              (component 'ui/badge
                (list 'text priority
                      'class (if (equal? priority "high") "alert" "warn")))))
      (component 'ui/actions
        (list 'actions sentry--detail-actions 'class "sentry-actions"))
      (component 'ui/card
        (list 'title "Error" 'open? #t
              'badge (sentry--text (sentry--get metadata 'type))
              'body
              (list (list 'tag "pre" 'class "sentry-exception"
                          'text (if (equal? exception "")
                                    "No exception message was returned."
                                    exception)))))
      (component 'ui/card
        (list 'title "Signal" 'open? #t
              'body (list (component 'ui/kv
                            (list 'pairs (sentry--summary-pairs issue))))))
      (component 'ui/card
        (list 'title "Where" 'open? #t
              'body (list (component 'ui/kv
                            (list 'pairs (sentry--location-pairs issue))))))
      (component 'ui/card
        (list 'title "Complete payload"
              'badge (if raw-open? "open" "expand")
              'open? raw-open?
              'click "sentry:raw"
              'body
              (list (list 'tag "pre" 'class "sentry-raw"
                          'text (sentry--pretty-json issue))))))))

(define (sentry--issue-text issue)
  (let* ((metadata (sentry--get issue 'metadata))
         (exception (sentry--text (sentry--get metadata 'value))))
    (string-append
      (sentry--text (sentry--get issue 'shortId)) "  "
      (sentry--issue-title issue) "\n\n"
      "Exception\n"
      (if (equal? exception "") "No exception message was returned." exception)
      "\n\nRaw issue JSON\n"
      (sentry--pretty-json issue))))

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
    (if (sentry--error? issue)
        (begin
          (buffer-set-local! buf 'render-mode "text")
          (buffer-set-local! buf 'render-blocks '())
          (sentry--replace-buffer!
            buf (string-append (sentry--error-message issue) "\n")))
        (begin
          (sentry--replace-buffer! buf (sentry--issue-text issue))
          (buffer-set-local! buf 'sentry-detail-issue issue)
          (buffer-set-local! buf 'render-mode "blocks")
          (buffer-set-local! buf 'render-blocks
            (sentry--issue-blocks
              issue
              (and (buffer-local buf 'sentry-raw-open?) #t)))))))

(define (sentry--detail-setup! buf)
  (sentry--join-group! buf)
  (desktop-skip! buf 'render-blocks)
  (desktop-skip! buf 'sentry-detail-issue)
  (local-set-key* buf "a" "sentry-ask-agent")
  (local-set-key* buf "o" "sentry-open-web")
  (local-set-key* buf "R" "sentry-resolve")
  (local-set-key* buf "g" "sentry-detail-refresh")
  (local-set-key* buf "e" "sentry-events")
  (local-set-key* buf "q" "quit-window")
  ;; fetch only when the buffer has nothing to show: this setup also
  ;; runs on every wake (buffer switcher preview, desktop restore), and
  ;; an unconditional fetch froze the UI for the network round trip
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
          (sentry--events-text events)))))

(define (sentry--events-setup! buf)
  (sentry--join-group! buf)
  (local-set-key* buf "g" "sentry-events-refresh")
  (local-set-key* buf "q" "quit-window")
  ;; same wake rule as the detail view: no fetch when text is cached
  (let ((issue-id (buffer-local buf 'sentry-issue-id)))
    (when (and issue-id (= (buffer-size buf) 0))
      (sentry--render-events! buf issue-id))))

(define *sentry-agent-send*
  (lambda (chat prompt) (agent-continue! chat prompt)))

(define *sentry-open-url*
  (lambda (url) (tab-open url)))

(define (sentry--agent-prompt buf issue)
  (string-append
    "Investigate Sentry issue "
    (sentry--text (sentry--get issue 'shortId))
    ". Read the complete issue in buffer "
    buf
    ". Find the cause, inspect the related source, and propose or implement a fix. "
    "Do not resolve the Sentry issue until I ask."))

(define (sentry--ask-agent! buf)
  (let ((issue (buffer-local buf 'sentry-detail-issue)))
    (when issue
      (let ((chat (group-chat *sentry-group*)))
        (*sentry-agent-send* chat (sentry--agent-prompt buf issue))
        (group-chat-show! *sentry-group*)))))

(define (sentry--open-in-sentry! buf)
  (let* ((issue (buffer-local buf 'sentry-detail-issue))
         (url (and issue (sentry--get issue 'permalink))))
    (when url (*sentry-open-url* url))))

(define (sentry--resolve-now! buf issue-id)
  (let ((reply (sentry-resolve-issue issue-id)))
    (if (sentry--error? reply)
        (message (sentry--error-message reply))
        (begin
          (message (string-append "Resolved Sentry issue " issue-id))
          (when (buffer-exists? *sentry-buffer*)
            (list-refresh! *sentry-buffer*))
          (sentry--render-detail! buf issue-id)))))

(define (sentry--confirm-resolve! buf)
  (let* ((issue-id (buffer-local buf 'sentry-issue-id))
         (issue (buffer-local buf 'sentry-detail-issue))
         (short-id (sentry--text (sentry--get issue 'shortId))))
    (when issue-id
      (y-or-n
        (string-append "Resolve " short-id " in Sentry?")
        (lambda () (sentry--resolve-now! buf issue-id))))))

;;; --- the detail verbs, from the list --------------------------------------------
;;; The same keys the issue workspace binds act on the list's marked rows,
;;; or the row at point — one key works on one issue and on twelve.

;; a rendered detail buffer for ISSUE-ID, without displaying it
(define (sentry--ensure-detail! issue-id)
  (let ((buf (sentry--detail-buffer issue-id)))
    (buffer-create buf)
    (buffer-set-local! buf 'sentry-issue-id issue-id)
    (if (equal? (buffer-local buf 'mode-name) "sentry-detail-mode")
        (when (= (buffer-size buf) 0)
          (sentry--render-detail! buf issue-id))
        (with-current-buffer buf
          (lambda () (set-mode! "sentry-detail-mode"))))
    buf))

;; the short ids of ISSUES, joined for a message or a prompt
(define (sentry--short-ids issues)
  (string-join
    (map (lambda (i) (sentry--text (sentry--get i 'shortId))) issues)
    ", "))

(define (sentry--agent-prompt-lines issues)
  (let loop ((is issues) (acc '()))
    (if (null? is)
        (string-join (reverse acc) "\n")
        (let ((i (car is)))
          (loop (cdr is)
                (cons (string-append
                        "- " (sentry--text (sentry--get i 'shortId))
                        " — read the complete issue in buffer "
                        (sentry--detail-buffer (sentry--text (sentry--get i 'id))))
                      acc))))))

(define-command "sentry-list-ask-agent"
  "Send the marked issues, or the one at point, to the Sentry group agent"
  (lambda ()
    (let ((issues (list-targets *sentry-buffer*)))
      (unless (null? issues)
        (for-each (lambda (i)
                    (sentry--ensure-detail! (sentry--text (sentry--get i 'id))))
                  issues)
        (let ((chat (group-chat *sentry-group*)))
          (*sentry-agent-send* chat
            (if (null? (cdr issues))
                (sentry--agent-prompt
                  (sentry--detail-buffer (sentry--text (sentry--get (car issues) 'id)))
                  (car issues))
                (string-append
                  "Investigate these Sentry issues:\n"
                  (sentry--agent-prompt-lines issues)
                  "\nFind the causes, inspect the related source, and propose"
                  " or implement fixes. Do not resolve the Sentry issues"
                  " until I ask.")))
          (group-chat-show! *sentry-group*))))))

(define-command "sentry-list-open-web"
  "Open the marked issues, or the one at point, in Sentry"
  (lambda ()
    (for-each (lambda (i)
                (let ((url (sentry--get i 'permalink)))
                  (when url (*sentry-open-url* url))))
              (list-targets *sentry-buffer*))))

(define-command "sentry-list-resolve"
  "Resolve the marked issues, or the one at point, after confirmation"
  (lambda ()
    (let ((issues (list-targets *sentry-buffer*)))
      (unless (null? issues)
        (y-or-n
          (string-append "Resolve " (sentry--short-ids issues) " in Sentry?")
          (lambda ()
            (let loop ((is issues) (done 0))
              (if (null? is)
                  (message (string-append "Resolved " (number->string done)
                                          " Sentry issue(s)"))
                  (let ((reply (sentry-resolve-issue
                                 (sentry--text (sentry--get (car is) 'id)))))
                    (if (sentry--error? reply)
                        (begin (message (sentry--error-message reply))
                               (loop (cdr is) done))
                        (loop (cdr is) (+ done 1))))))
            (list-refresh! *sentry-buffer*)))))))

(on-block-click! 'sentry
  (lambda (buf id)
    (and (buffer-local buf 'sentry-issue-id)
         (cond
           ((equal? id "sentry:raw")
            (let* ((open? (and (buffer-local buf 'sentry-raw-open?) #t))
                   (issue (buffer-local buf 'sentry-detail-issue)))
              (buffer-set-local! buf 'sentry-raw-open? (not open?))
              (when issue
                (buffer-set-local! buf 'render-blocks
                  (sentry--issue-blocks issue (not open?)))))
            #t)
           ((equal? id "sentry:ask")
            (sentry--ask-agent! buf) #t)
           ((equal? id "sentry:open")
            (sentry--open-in-sentry! buf) #t)
           ((equal? id "sentry:resolve")
            (sentry--confirm-resolve! buf) #t)
           ((equal? id "sentry:events")
            (with-current-buffer buf (lambda () (run-command "sentry-events"))) #t)
           ((equal? id "sentry:refresh")
            (with-current-buffer buf
              (lambda () (run-command "sentry-detail-refresh"))) #t)
           (else #f)))))

;;; --- modes and commands -------------------------------------------------------

(domain! 'sentry)
(effects! '(write external))

(mode-icon! "sentry-detail-mode" "")

(define-mode "sentry-detail-mode"
  (lambda () (sentry--detail-setup! (current-buffer))))

(mode-doc! "sentry-detail-mode"
  "An actionable Sentry issue workspace. `a` asks the agent. `R` resolves after confirmation.")

(register-context-provider! "sentry-detail-mode"
  (lambda (buf)
    (let* ((issue (buffer-local buf 'sentry-detail-issue))
           (short-id (and issue (sentry--get issue 'shortId))))
      (and short-id
           (string-append
             "Sentry issue "
             (sentry--text short-id)
             " is open in "
             buf
             ". Read that buffer for the complete payload.")))))

(define-command "sentry-ask-agent" "Send this issue to the Sentry group agent"
  (lambda () (sentry--ask-agent! (current-buffer))))

(define-command "sentry-open-web" "Open this issue in Sentry"
  (lambda () (sentry--open-in-sentry! (current-buffer))))

(define-command "sentry-resolve" "Resolve this issue in Sentry after confirmation"
  (lambda () (sentry--confirm-resolve! (current-buffer))))

(mode-icon! "sentry-events-mode" "")

(define-mode "sentry-events-mode"
  (lambda () (sentry--events-setup! (current-buffer))))

(mode-doc! "sentry-events-mode"
  "Safe event identifiers for one Sentry issue. `g` refreshes the list.")

(define-command "sentry-open" "Show structured details for the Sentry issue on this row"
  (lambda ()
    (let ((issue (list-current *sentry-buffer*)))
      (when issue
        (let* ((issue-id (sentry--get issue 'id))
               (buf (sentry--detail-buffer issue-id)))
          (buffer-create buf)
          (buffer-set-local! buf 'sentry-issue-id issue-id)
          (display-buffer-other-window! buf)
          (with-current-buffer
            buf
            (lambda ()
              (if (equal? (buffer-local buf 'mode-name) "sentry-detail-mode")
                  (sentry--render-detail! buf issue-id)
                  (set-mode! "sentry-detail-mode")))))))))

(define-command "sentry-refresh" "Refresh the Sentry issue list"
  (lambda () (list-refresh! *sentry-buffer*)))

(define-command "sentry-detail-refresh" "Refresh this Sentry issue detail"
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
           "RET opens structured issue details. `g` refreshes the list. "
           "`m` marks rows; `a`, `o` and `R` act on the marked rows, or the "
           "row at point — ask the agent, open in Sentry, resolve.")
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
    'footer (lambda (buf)
              '(("RET" "detail") ("m" "mark") ("a" "agent") ("o" "web")
                ("R" "resolve") ("/" "filter") ("g" "refresh") ("q" "quit")))
    'key (lambda (buf issue) (sentry--get issue 'id))
    'keys '(("RET" "sentry-open") ("g" "sentry-refresh") ("q" "quit-window")
            ("a" "sentry-list-ask-agent") ("o" "sentry-list-open-web")
            ("R" "sentry-list-resolve"))))

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
(public! 'sentry-resolve-issue
  "(sentry-resolve-issue ISSUE-ID) — resolve one Sentry issue")
(public! 'sentry
  "M-x sentry — list unresolved production issues and open full formatted details")

(defrecipe! "inspect unresolved production errors"
  "(sentry)")
