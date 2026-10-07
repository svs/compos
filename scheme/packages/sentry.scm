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

;; The maximum rows one Sentry request returns.
(define sentry-limit 20)

(defcustom 'sentry-timeout 30
  "Seconds to wait for one Sentry request." 'group 'sentry)

(defcustom 'sentry-cache-ttl 120
  "Seconds the issue list serves its cached rows before a wake refetches."
  'group 'sentry)

(defcustom 'sentry-curl-program "curl"
  "The curl executable for Sentry requests." 'group 'sentry)

;;; --- small helpers ------------------------------------------------------------

(define (sentry--text value)
  (cond ((string? value) value)
        ((number? value) (number->string value))
        ((symbol? value) (symbol->string value))
        (else "")))

(define (sentry--config-escape text)
  (string-replace (string-replace (sentry--text text) "\\" "\\\\") "\"" "\\\""))

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
  (let ((dir (string-append (compos-home) "/tmp")))
    (make-directory! dir)
    (string-append dir "/sentry-" (number->string (current-time)) "-"
                   (number->string *sentry--seq*) ".conf")))

;; the key chain answers: the environment, a key file, or the secret provider
(define (sentry--token) (key-get "SENTRY_AUTH_TOKEN"))

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
                                      (sh-quote path)))))
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
                                      (sh-quote path)))))
            (delete-file! path)
            out)))))

(define *sentry-transport* sentry--curl)
(define *sentry-write-transport* sentry--curl-write)

;; The async transport: K gets the wire when curl answers, and the
;; calling lane moves on. The issue list fetches through this seam — a
;; synchronous request would hold the UI lane for the network round
;; trip. Tests replace this seam with a synchronous stub.
(define (sentry--curl-async url k)
  (let ((token (sentry--token)))
    (if (not token)
        (k "SENTRY_AUTH_TOKEN is not configured\n000")
        (let ((path (sentry--tmp-path)))
          (write-file! path (sentry--curl-config url token))
          (shell-command->string
            (string-append sentry-curl-program " --config "
                           (sh-quote path))
            (lambda (out)
              (delete-file! path)
              (k out)))))))

(define *sentry-async-transport* sentry--curl-async)

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
      (or (plist-get (car (plist-get reply 'errors)) 'message)
          "Sentry request failed")))

;; Parse every result into JSON or one stable error plist. Do not include an
;; HTTP response body in an error because it can hold deployment details.
(define (sentry--parse-reply wire)
  (let* ((parts (sentry--split-status wire))
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

(define (sentry--request url)
  (sentry--parse-reply (*sentry-transport* url)))

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
  (list 'id (plist-get issue 'id)
        'shortId (plist-get issue 'shortId)
        'title (sentry--redact (plist-get issue 'title))
        'status (plist-get issue 'status)
        'level (plist-get issue 'level)
        'culprit (sentry--redact (plist-get issue 'culprit))
        'count (plist-get issue 'count)
        'userCount (plist-get issue 'userCount)
        'firstSeen (plist-get issue 'firstSeen)
        'lastSeen (plist-get issue 'lastSeen)
        'permalink (plist-get issue 'permalink)))

(define (sentry--safe-event event)
  (list 'eventID (plist-get event 'eventID)
        'dateCreated (plist-get event 'dateCreated)
        'environment (plist-get event 'environment)
        'platform (plist-get event 'platform)
        'culprit (sentry--redact (plist-get event 'culprit))))

(define (sentry--issues-url query environment time-range count)
  (sentry--url
    (sentry--project-path "issues/")
    (list (list "environment" (or environment sentry-environment))
          (list "statsPeriod" (or time-range sentry-time-range))
          (list "query" (or query sentry-query))
          (list "per_page" count))))

(define (sentry--parse-issues reply count)
  (if (sentry--error? reply)
      reply
      (map sentry--safe-issue (take reply count))))

(define (sentry-list-issues &optional query environment time-range limit)
  (let ((count (sentry--limit limit)))
    (sentry--parse-issues
      (sentry--request (sentry--issues-url query environment time-range count))
      count)))

(define (sentry--issue-url issue-id)
  (sentry--url
    (sentry--org-path
      (string-append "issues/" (url-encode (sentry--text issue-id)) "/"))
    '()))

(define (sentry-issue-detail issue-id)
  (sentry--request (sentry--issue-url issue-id)))

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
        (map sentry--safe-event (take reply count)))))

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

(define (sentry--age-label iso)
  ;; ISO-8601 UTC as an age: "now", "5m", "2h", "26d"
  (if (not (and (string? iso) (>= (string-length iso) 16)))
      ""
      (let* ((n (lambda (a z) (string->number (substring iso a z))))
             (secs (- (parts->time (n 0 4) (n 5 7) (n 8 10) (n 11 13) (n 14 16))
                      (parts->time 1970 1 1 0 0)))
             (age (max 0 (- (current-time) secs))))
        (cond ((< age 60) "now")
              ((< age 3600) (string-append (number->string (quotient age 60)) "m"))
              ((< age 86400) (string-append (number->string (quotient age 3600)) "h"))
              (else (string-append (number->string (quotient age 86400)) "d"))))))

(define (sentry--issue-cells buf issue)
  ;; two lines: the title owns the first, the level is the bar beside it
  (let* ((level (plist-get issue 'level))
         (face (cond ((equal? level "error") "alert")
                     ((equal? level "warning") "warn")
                     (else "dim")))
         (count (sentry--text (plist-get issue 'count))))
    (list
      (list (list "▌" face)
            (sentry--redact (plist-get issue 'title))
            (list (sentry--age-label (plist-get issue 'lastSeen)) "dim"))
      (list " "
            (list (plist-get issue 'shortId) "accent")
            (list (string-append count (if (equal? count "1") " event" " events")) "dim")))))

(define (sentry--issue-meta buf)
  (string-append
    (number->string (length (list-entries buf))) " unresolved · "
    sentry-org "/" sentry-project " · " sentry-environment " · " sentry-time-range))

;; The cache fetch: the rows land off the UI lane, and K gets them when
;; the request answers. (k #f) keeps the rows the buffer already shows.
(define (sentry--fetch-issues buf k)
  (sentry--join-group! buf)
  (let ((count (sentry--limit #f)))
    (*sentry-async-transport*
      (sentry--issues-url #f #f #f count)
      (lambda (wire)
        (let ((reply (sentry--parse-issues (sentry--parse-reply wire) count)))
          (if (sentry--error? reply)
              (begin (message (sentry--error-message reply)) (k #f))
              (k reply)))))))

;; the cache IS the source of truth: 'rows serves what the last fetch
;; put in the buffer, and never reaches the network
(define (sentry--issue-rows buf)
  (sentry--join-group! buf)
  (list-entries buf))

(define (sentry--safe-field label value)
  (let ((text (sentry--redact value)))
    (if (equal? text "") "" (string-append label ": " text "\n"))))

(define (sentry--pretty-json value)
  (json-encode value #t))

(define (sentry--issue-title issue)
  (let* ((title (string-trim (sentry--text (plist-get issue 'title))))
         (metadata (plist-get issue 'metadata))
         (kind (string-trim (sentry--text (plist-get metadata 'type)))))
    (cond ((not (equal? title "")) (sentry--redact title))
          ((not (equal? kind "")) kind)
          (else (sentry--text (plist-get issue 'shortId))))))

(define (sentry--summary-pairs issue)
  (list
    (list "Status" (sentry--text (plist-get issue 'status)))
    (list "Priority" (sentry--text (plist-get issue 'priority)))
    (list "Level" (sentry--text (plist-get issue 'level)))
    (list "Events" (sentry--text (plist-get issue 'count)))
    (list "Users" (sentry--text (plist-get issue 'userCount)))
    (list "First seen" (sentry--text (plist-get issue 'firstSeen)))
    (list "Last seen" (sentry--text (plist-get issue 'lastSeen)))
    (list "Platform" (sentry--text (plist-get issue 'platform)))))

(define (sentry--location-pairs issue)
  (let ((metadata (plist-get issue 'metadata)))
    (list
      (list "Culprit" (sentry--text (plist-get issue 'culprit)))
      (list "Exception" (sentry--text (plist-get metadata 'type)))
      (list "Function" (sentry--text (plist-get metadata 'function)))
      (list "File" (sentry--text (plist-get metadata 'filename)))
      (list "Issue URL" (sentry--text (plist-get issue 'permalink))))))

(define (sentry--tag-lines issue)
  (map (lambda (tag)
         (list 'tag "div" 'class "sentry-tag"
               'segs (list
                       (list "c-kv-key" (sentry--text (plist-get tag 'name)))
                       (list "c-kv-value"
                             (string-append
                               "  "
                               (sentry--text (plist-get tag 'totalValues))
                               " values")))))
       (or (plist-get issue 'tags) '())))

(define sentry--detail-actions
  '(("sentry:ask" "Ask agent" "a")
    ("sentry:open" "Open in Sentry" "o")
    ("sentry:resolve" "Resolve" "R")
    ("sentry:events" "Events" "e")
    ("sentry:refresh" "Refresh" "g")))

(define (sentry--issue-blocks issue raw-open?)
  (let* ((metadata (plist-get issue 'metadata))
         (exception (sentry--text (plist-get metadata 'value)))
         (status (sentry--text (plist-get issue 'status)))
         (priority (sentry--text (plist-get issue 'priority))))
    (list
      (component 'ui/section
        (list 'title
          (string-append
            (sentry--text (plist-get issue 'shortId))
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
              'badge (sentry--text (plist-get metadata 'type))
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
  (let* ((metadata (plist-get issue 'metadata))
         (exception (sentry--text (plist-get metadata 'value))))
    (string-append
      (sentry--text (plist-get issue 'shortId)) "  "
      (sentry--issue-title issue) "\n\n"
      "Exception\n"
      (if (equal? exception "") "No exception message was returned." exception)
      "\n\nRaw issue JSON\n"
      (sentry--pretty-json issue))))

(define (sentry--detail-buffer issue-id)
  (string-append "*Sentry issue: " (sentry--text issue-id) "*"))

;; render one fetched issue (or one error) into the detail buffer
(define (sentry--apply-detail! buf issue)
  (if (sentry--error? issue)
      (begin
        (buffer-set-local! buf 'render-mode "text")
        (buffer-set-local! buf 'render-blocks '())
        (buffer-set-text!
          buf (string-append (sentry--error-message issue) "\n") #t))
      (begin
        (buffer-set-text! buf (sentry--issue-text issue) #t)
        (buffer-set-local! buf 'sentry-detail-issue issue)
        (buffer-set-local! buf 'render-mode "blocks")
        (buffer-set-local! buf 'render-blocks
          (sentry--issue-blocks
            issue
            (and (buffer-local buf 'sentry-raw-open?) #t))))))

(define (sentry-preview-project! copy source)
  ;; The durable text contains the same issue payload as the transient cards.
  ;; Rebuild presentation only: no source wake, cache refresh, or HTTP request.
  (let* ((text (buffer-text copy))
         (parts (string-split text "\n\nRaw issue JSON\n"))
         (issue (or (buffer-local source 'sentry-detail-issue)
                    (and (> (length parts) 1) (json-parse (cadr parts))))))
    (when (and (pair? issue) (plist-get issue 'id))
      (buffer-set-locals! copy
        (list 'render-mode "blocks"
              'render-blocks (sentry--issue-blocks issue #f))))))

(listing-preview-projector! "sentry-detail-mode" sentry-preview-project!)

;; the cache fetch: the issue lands off the UI lane. An error renders in
;; the buffer, and (k #f) leaves the cache unstamped so a wake retries.
(define (sentry--fetch-detail buf k)
  (let ((issue-id (buffer-local buf 'sentry-issue-id)))
    (if (not issue-id)
        (k #f)
        (*sentry-async-transport*
          (sentry--issue-url issue-id)
          (lambda (wire)
            (let ((reply (sentry--parse-reply wire)))
              (if (sentry--error? reply)
                  (begin (sentry--apply-detail! buf reply) (k #f))
                  (k reply))))))))

(define (sentry--detail-setup! buf)
  (sentry--join-group! buf)
  (desktop-skip! buf 'render-blocks)
  (desktop-skip! buf 'sentry-detail-issue)
  
  ;; the issue comes through the buffer cache: a wake draws what the
  ;; buffer holds and fetches only past the TTL. An empty buffer, or one
  ;; whose blocks source did not survive a restart, fetches now — off
  ;; the lane, so no wake freezes the UI for the network round trip.
  (let ((issue-id (buffer-local buf 'sentry-issue-id)))
    (when issue-id
      (cache-declare! buf sentry--fetch-detail
        (lambda (b issue) (sentry--apply-detail! b issue))
        sentry-cache-ttl)
      (if (or (= (buffer-size buf) 0)
              (not (buffer-local buf 'sentry-detail-issue)))
          (cache-refresh! buf)
          (cache-wake! buf)))))

(define (sentry--event-line event)
  (string-append
    (string-pad-right (sentry--truncate (plist-get event 'dateCreated) 24) 24) "  "
    (string-pad-right (sentry--truncate (plist-get event 'environment) 10) 10) "  "
    (string-pad-right (sentry--truncate (plist-get event 'platform) 12) 12) "  "
    (sentry--truncate (plist-get event 'eventID) 40)))

(define (sentry--events-text events)
  (if (null? events)
      "No events matched.\n"
      (fold (lambda (text event)
              (string-append text (sentry--event-line event) "\n"))
            "Time                      Environment  Platform      Event ID\n\n"
            events)))

(define (sentry--render-events! buf issue-id)
  (let ((events (sentry-issue-events issue-id)))
    (buffer-set-text!
      buf
      (if (sentry--error? events)
          (string-append (sentry--error-message events) "\n")
          (sentry--events-text events)) #t)))

(define (sentry--events-setup! buf)
  (sentry--join-group! buf)
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
    (sentry--text (plist-get issue 'shortId))
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
         (url (and issue (plist-get issue 'permalink))))
    (when url (*sentry-open-url* url))))

(define (sentry--resolve-now! buf issue-id)
  (let ((reply (sentry-resolve-issue issue-id)))
    (if (sentry--error? reply)
        (message (sentry--error-message reply))
        (begin
          (message (string-append "Resolved Sentry issue " issue-id))
          (when (buffer-exists? *sentry-buffer*)
            (cache-refresh! *sentry-buffer*))
          (cache-refresh! buf)))))

(define (sentry--confirm-resolve! buf)
  (let* ((issue-id (buffer-local buf 'sentry-issue-id))
         (issue (buffer-local buf 'sentry-detail-issue))
         (short-id (sentry--text (plist-get issue 'shortId))))
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
          (cache-refresh! buf))
        (with-current-buffer buf
          (lambda () (set-mode! "sentry-detail-mode"))))
    buf))

;; the short ids of ISSUES, joined for a message or a prompt
(define (sentry--short-ids issues)
  (string-join
    (map (lambda (i) (sentry--text (plist-get i 'shortId))) issues)
    ", "))

(define (sentry--agent-prompt-lines issues)
  (let loop ((is issues) (acc '()))
    (if (null? is)
        (string-join (reverse acc) "\n")
        (let ((i (car is)))
          (loop (cdr is)
                (cons (string-append
                        "- " (sentry--text (plist-get i 'shortId))
                        " — read the complete issue in buffer "
                        (sentry--detail-buffer (sentry--text (plist-get i 'id))))
                      acc))))))

(define-command "sentry-list-ask-agent"
  "Send the marked issues, or the one at point, to the Sentry group agent"
  (lambda ()
    (let ((issues (list-targets *sentry-buffer*)))
      (unless (null? issues)
        (for-each (lambda (i)
                    (sentry--ensure-detail! (sentry--text (plist-get i 'id))))
                  issues)
        (let ((chat (group-chat *sentry-group*)))
          (*sentry-agent-send* chat
            (if (null? (cdr issues))
                (sentry--agent-prompt
                  (sentry--detail-buffer (sentry--text (plist-get (car issues) 'id)))
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
                (let ((url (plist-get i 'permalink)))
                  (when url (*sentry-open-url* url))))
              (list-targets *sentry-buffer*))))

;; After a resolve the list drops the row, but a window can keep showing
;; a dead issue's detail. That window advances to the row the highlight
;; lands on, and the stale detail buffers die.
(define (sentry--advance-details! resolved-ids)
  (let* ((stale (map sentry--detail-buffer resolved-ids))
         (shown (filter (lambda (w) (member (cadr w) stale)) (window-list)))
         (rest (filter (lambda (e)
                         (not (member (sentry--text (plist-get e 'id))
                                      resolved-ids)))
                       (list-entries *sentry-buffer*)))
         (i (or (list-index *sentry-buffer*) 0))
         (next (and (pair? rest)
                    (nth (min i (- (length rest) 1)) rest))))
    (when (and (pair? shown) next)
      (display-buffer-detail!
        (sentry--ensure-detail! (plist-get next 'id)) *sentry-buffer*))
    (for-each (lambda (b)
                (when (and (buffer-exists? b)
                           (not (member b (map cadr (window-list)))))
                  (buffer-kill! b)))
              stale)))

(define-command "sentry-list-resolve"
  "Resolve the marked issues, or the one at point, after confirmation"
  (lambda ()
    (let ((issues (list-targets *sentry-buffer*)))
      (unless (null? issues)
        (y-or-n
          (string-append "Resolve " (sentry--short-ids issues) " in Sentry?")
          (lambda ()
            (let loop ((is issues) (done 0) (ok '()))
              (if (null? is)
                  (begin
                    (message (string-append "Resolved " (number->string done)
                                            " Sentry issue(s)"))
                    (sentry--advance-details! (reverse ok)))
                  (let* ((id (sentry--text (plist-get (car is) 'id)))
                         (reply (sentry-resolve-issue id)))
                    (if (sentry--error? reply)
                        (begin (message (sentry--error-message reply))
                               (loop (cdr is) done ok))
                        (loop (cdr is) (+ done 1) (cons id ok))))))
            (cache-refresh! *sentry-buffer*)))))))

(add-hook! (list 'block-click 'sentry)
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

(mode-keys! "sentry-detail-mode"
  '(
    ("a" "sentry-ask-agent")
    ("o" "sentry-open-web")
    ("R" "sentry-resolve")
    ("g" "sentry-detail-refresh")
    ("e" "sentry-events")
    ("q" "quit-window")))

(mode-doc! "sentry-detail-mode"
  "An actionable Sentry issue workspace. `a` asks the agent. `R` resolves after confirmation.")

(register-context-provider! "sentry-detail-mode"
  (lambda (buf)
    (let* ((issue (buffer-local buf 'sentry-detail-issue))
           (short-id (and issue (plist-get issue 'shortId))))
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

(mode-keys! "sentry-events-mode"
  '(
    ("g" "sentry-events-refresh")
    ("q" "quit-window")))

(mode-doc! "sentry-events-mode"
  "Safe event identifiers for one Sentry issue. `g` refreshes the list.")

(define-command "sentry-open" "Show structured details for the Sentry issue on this row"
  (lambda ()
    (let ((issue (list-current *sentry-buffer*)))
      (when issue
        (let* ((issue-id (plist-get issue 'id))
               (buf (sentry--detail-buffer issue-id)))
          (buffer-create buf)
          (buffer-set-local! buf 'sentry-issue-id issue-id)
          ;; the row already knows the issue: a first open draws it now,
          ;; and the full fetch replaces it when it lands. An empty
          ;; window for the network round trip reads as a hang.
          (when (= (buffer-size buf) 0)
            (sentry--apply-detail! buf issue))
          (display-buffer-detail! buf *sentry-buffer*)
          (with-current-buffer
            buf
            (lambda ()
              ;; an open detail is a cache wake, not a fetch: RET on the
              ;; same row again serves what the buffer holds until the
              ;; TTL passes; `g` in the detail is the explicit refetch
              (if (equal? (buffer-local buf 'mode-name) "sentry-detail-mode")
                  (cache-wake! buf)
                  (set-mode! "sentry-detail-mode")))))))))

(define-command "sentry-refresh" "Refresh the Sentry issue list"
  (lambda () (cache-refresh! *sentry-buffer*)))

(define-command "sentry-detail-refresh" "Refresh this Sentry issue detail"
  (lambda ()
    (let ((issue-id (buffer-local (current-buffer) 'sentry-issue-id)))
      (when issue-id (cache-refresh! (current-buffer))))))

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
           "`SPC` marks rows; `a`, `o` and `R` act on the marked rows, or the "
           "row at point — ask the agent, open in Sentry, resolve.")
    'buffer *sentry-buffer*
    'rows sentry--issue-rows
    'cache-fetch sentry--fetch-issues
    'cache-ttl sentry-cache-ttl
    'row-columns (lambda (buf)
                   (list (list (list "" 1) (list "title" #f 'left 'end)
                               (list "seen" 4 'right))
                         (list (list "" 1) (list "issue" #f)
                               (list "events" 11 'right))))
    'row-cells sentry--issue-cells
    'title (lambda (buf) "Sentry issues")
    'meta sentry--issue-meta
    'total (lambda (buf) (length (list-entries buf)))
    'footer (lambda (buf)
              '(("RET" "detail") ("SPC" "mark") ("a" "agent") ("o" "web")
                ("R" "resolve") ("/" "filter") ("g" "refresh") ("q" "quit")))
    'key (lambda (buf issue) (plist-get issue 'id))
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
