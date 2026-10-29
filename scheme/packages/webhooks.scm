;;; webhooks.scm --- named webhook endpoints on one inbound HTTP server.
;;;
;;; A webhook is a path, the methods it takes, and a handler. Every
;;; endpoint shares the server named "webhooks", so a new endpoint is live
;;; the moment it is defined: the server reads the registry per request.
;;;
;;;   (define-webhook! "github" '(token "s3cret")
;;;     (lambda (request) (message (plist-get (plist-get request 'json) 'action)) "ok"))
;;;
;;; An endpoint without a handler publishes each request to the event log
;;; as topic webhook:NAME, kind received. With 'data 'json the event's data
;;; is the parsed JSON body alone, so a listener's 'match reads the payload.

(package! "webhooks")
(category! 'system)
(domain! 'web-servers)
(effects! '(write))

(defcustom 'webhooks-host "127.0.0.1"
  "The address the webhook server listens on: an IP address, localhost, or any."
  'group 'webhooks 'type 'string)

(defcustom 'webhooks-port 4791
  "The port of the webhook server."
  'group 'webhooks 'type 'integer)

(defcustom 'webhooks-max-body 1048576
  "The largest request body the webhook server reads, in bytes."
  'group 'webhooks 'type 'integer)

(defcustom 'webhooks-saved '()
  "The webhooks M-x webhook-define made, as (NAME PATH TOKEN) rows; each one publishes webhook:NAME events."
  'group 'webhooks 'type 'sexp
  ;; custom.scm loads after this package, so the saved rows arrive here
  'set (lambda (rows) (webhooks--define-saved!)))

(defcustom 'webhooks-tunnel-host #f
  "The public hostname of the Cloudflare tunnel in front of the server, such as compos.example.com; #f when there is none."
  'group 'webhooks 'type 'string)

(defcustom 'webhooks-tunnel-token #f
  "The connector token of that Cloudflare tunnel; cloudflared runs with it while the server listens."
  'group 'webhooks 'type 'secret 'env "WEBHOOKS_TUNNEL_TOKEN")

(defcustom 'webhooks-enabled #f
  "Start the webhook server when this package loads."
  'group 'webhooks 'type 'boolean
  ;; custom.scm loads after this package, so the saved value arrives here
  'set (lambda (on)
         (cond ((and on (not (webhooks-running?))) (ignore-errors (lambda () (webhooks-start!))))
               ((and (not on) (webhooks-running?)) (webhooks-stop!)))))

;; the registry table webhook: NAME -> the endpoint plist: name path methods token peers handler
;; the server's detail plist while it runs, else #f
(define *webhooks-server* #f)

(effects! '(pure))

(define (webhooks--reply status text)
  (list 'status status 'headers '(("content-type" "text/plain")) 'body text))

(define (webhooks--header request name)
  "(webhooks--header REQUEST NAME) — the value of the lowercase header NAME, or #f"
  (let ((hit (assoc name (or (plist-get request 'headers) '()))))
    (and hit (cadr hit))))

(define (webhooks--authorized? hook request)
  "(webhooks--authorized? HOOK REQUEST) — #t when HOOK has no token, or REQUEST carries it"
  (let ((token (plist-get hook 'token)))
    (or (not token)
        (equal? (webhooks--header request "x-webhook-token") token)
        (equal? (webhooks--header request "authorization") (string-append "Bearer " token)))))

(define (webhooks--peer-ok? hook request)
  (let ((peers (plist-get hook 'peers)))
    (or (not peers) (and (member (plist-get request 'remote-address) peers) #t))))

(define (webhooks--tunneled? request)
  "(webhooks--tunneled? REQUEST) — #t when REQUEST came in through the Cloudflare tunnel"
  (and (webhooks--header request "cf-ray") #t))

(define (webhooks--json request)
  "(webhooks--json REQUEST) — the parsed body when it is JSON, else #f"
  (let ((type (or (webhooks--header request "content-type") ""))
        (body (or (plist-get request 'body) "")))
    (and (string-contains? type "json")
         (not (equal? body ""))
         (json-parse body))))

(define (webhooks--response value)
  "(webhooks--response VALUE) — a handler's answer as a response: a plist with 'status stays, a string is the body, anything else is ok"
  (cond ((string? value) (webhooks--reply 200 value))
        ((and (pair? value) (plist-get value 'status)) value)
        (else (webhooks--reply 200 "ok"))))

(effects! '(read))

(define (webhook-get name)
  "(webhook-get NAME) — the endpoint plist named NAME, or #f"
  (registry-lookup 'webhook name))

(define (webhook-list)
  "(webhook-list) — every endpoint as (NAME METHODS PATH)"
  (map (lambda (e) (list (car e) (plist-get (cadr e) 'methods) (plist-get (cadr e) 'path)))
       (registry-list 'webhook)))

(define (webhook-url name)
  "(webhook-url NAME) — the URL of endpoint NAME on the running server, the tunnel's when it is up, or #f"
  (let ((hook (webhook-get name)))
    (and hook *webhooks-server*
         (string-append (if (and (plist-get hook 'public) (webhooks-tunnel-up?))
                            (string-append "https://" webhooks-tunnel-host)
                            (plist-get *webhooks-server* 'url))
                        (plist-get hook 'path)))))

(define (webhooks-running?)
  "(webhooks-running?) — #t while the webhook server listens"
  (and *webhooks-server* #t))

(define (webhooks-tunnel-up?)
  "(webhooks-tunnel-up?) — #t while cloudflared carries the tunnel"
  (and webhooks-tunnel-host (endpoint-connected? "webhooks-tunnel")))

(effects! '(write))

(define (webhooks--publish! hook request json)
  (event-publish! (string-append "webhook:" (plist-get hook 'name)) 'received
                  (if (and json (equal? (plist-get hook 'data) 'json))
                      json
                      (list 'method (plist-get request 'method)
                            'path (plist-get request 'path)
                            'query (plist-get request 'query)
                            'headers (plist-get request 'headers)
                            'body (plist-get request 'body)
                            'json json
                            'remote-address (plist-get request 'remote-address)))))

(define (webhooks--handle request)
  "(webhooks--handle REQUEST) — route one request to its endpoint and answer the response"
  (let* ((path (plist-get request 'path))
         (hit (filter (lambda (e) (equal? (plist-get (cadr e) 'path) path)) (registry-list 'webhook)))
         (hook (and (pair? hit) (cadr (car hit)))))
    (cond ((or (not hook) (and (webhooks--tunneled? request) (not (plist-get hook 'public))))
           (webhooks--reply 404 "not found"))
          ((not (member (plist-get request 'method) (plist-get hook 'methods)))
           (webhooks--reply 405 "method not allowed"))
          ((not (webhooks--peer-ok? hook request)) (webhooks--reply 403 "forbidden"))
          ((not (webhooks--authorized? hook request)) (webhooks--reply 401 "unauthorized"))
          (else
           (let ((json (webhooks--json request))
                 (handler (plist-get hook 'handler)))
             (if handler
                 (webhooks--response
                  (handler (append (list 'webhook (plist-get hook 'name) 'json json) request)))
                 (begin (webhooks--publish! hook request json)
                        (webhooks--reply 200 "ok"))))))))

(define (define-webhook! name &optional opts handler)
  "(define-webhook! NAME [OPTS] [HANDLER]) — define or replace endpoint NAME; OPTS is a plist of 'path (default /hooks/NAME), 'methods (default POST only), 'token, 'peers, 'data ('json: the event's data is the JSON body alone) and 'public (#t: it answers through the tunnel too)"
  (let* ((opts (or opts '()))
         (path (or (plist-get opts 'path) (string-append "/hooks/" name)))
         (hook (list 'name name
                     'path (if (string-prefix? "/" path) path (string-append "/" path))
                     'methods (or (plist-get opts 'methods) (list "POST"))
                     'token (plist-get opts 'token)
                     'peers (plist-get opts 'peers)
                     'data (plist-get opts 'data)
                     'public (and (plist-get opts 'public) #t)
                     'handler handler))
         (clash (filter (lambda (e) (and (not (equal? (car e) name))
                                         (equal? (plist-get (cadr e) 'path) (plist-get hook 'path))))
                        (registry-list 'webhook))))
    (if (pair? clash)
        (error (string-append "webhook " (car (car clash)) " already takes " (plist-get hook 'path)))
        (registry-register! 'webhook name hook))))

(define (webhook-remove! name)
  "(webhook-remove! NAME) — drop endpoint NAME; #t when it was there"
  (registry-forget! 'webhook name))

(define *webhook-workflows* '())  ; (NAME HANDLER): the handler symbol of the workflow on webhook:NAME

(define (webhooks--workflow-name name) (string-append "webhook-" name))

(define (webhook-workflow name)
  "(webhook-workflow NAME) — the handler of the workflow attached to webhook NAME, or #f"
  (let ((e (assoc name *webhook-workflows*))) (if e (cadr e) #f)))

(define (webhook-attach-workflow! name handler)
  "(webhook-attach-workflow! NAME HANDLER) — run (HANDLER KEY EVENTS) on every webhook:NAME event, as the workflow webhook-NAME; HANDLER is a quoted name"
  (define-workflow! (webhooks--workflow-name name)
    'listen (list (string-append "webhook:" name))
    'handle handler)
  (set! *webhook-workflows* (append (filter (lambda (e) (not (equal? (car e) name))) *webhook-workflows*)
                                    (list (list name handler))))
  name)

(define (webhook-detach-workflow! name)
  "(webhook-detach-workflow! NAME) — stop the workflow on webhook NAME; its position stays"
  (when (webhook-workflow name)
    (ignore-errors (lambda () (workflow-stop! (webhooks--workflow-name name))))
    (set! *webhook-workflows* (filter (lambda (e) (not (equal? (car e) name))) *webhook-workflows*)))
  name)

(effects! '(write external))

(define (webhooks-start!)
  "(webhooks-start!) — listen on webhooks-host and webhooks-port; answers the server's URL"
  (web-server-stop! "webhooks")
  ;; started from a task, the server takes a lane of its own: the lane of
  ;; whoever called this may be an agent's, gone after its turn
  (set! *webhooks-server*
        (task-await
         (task-spawn
          (lambda ()
            (web-server-start! "webhooks"
                               (list 'host webhooks-host 'port webhooks-port
                                     'max-body webhooks-max-body)
                               (lambda (request) (webhooks--handle request)))))))
  (webhooks--tunnel-start!)
  (plist-get *webhooks-server* 'url))

(define (webhooks--tunnel-start!)
  (let ((token (secret-value 'webhooks-tunnel-token)))
    (when (and webhooks-tunnel-host token)
      (ignore-errors (lambda () (endpoint-stop! "webhooks-tunnel")))
      ;; from a task, like the server: the caller's lane may be gone after its turn
      (task-await
       (task-spawn
        (lambda ()
          (endpoint-start! "webhooks-tunnel"
                           (list 'command "cloudflared"
                                 'args (list "tunnel" "--no-autoupdate" "run")
                                 'env (list 'TUNNEL_TOKEN token)
                                 'framing "raw"))))))))

(define (webhooks-stop!)
  "(webhooks-stop!) — stop the webhook server; the endpoints stay defined"
  (web-server-stop! "webhooks")
  (ignore-errors (lambda () (endpoint-stop! "webhooks-tunnel")))
  (set! *webhooks-server* #f)
  #t)

(define-command "webhooks-start" "Start the webhook server"
  (lambda ()
    (let ((url (webhooks-start!)))
      (customize-save! 'webhooks-enabled #t)
      (message (string-append "webhooks on " url)))))

(define-command "webhooks-stop" "Stop the webhook server"
  (lambda () (webhooks-stop!) (customize-save! 'webhooks-enabled #f) (message "webhooks off")))

(define-command "webhooks-list" "Say every webhook endpoint and where it listens"
  (lambda ()
    (message
     (if (null? (registry-names 'webhook))
         "no webhooks defined"
         (string-join
          (map (lambda (row)
                 (string-append (car row) "  " (string-join (cadr row) ",") " "
                                (or (webhook-url (car row)) (caddr row))))
               (webhook-list))
          "\n")))))

(effects! '(write))

(define (webhooks--define-saved!)
  "(webhooks--define-saved!) — define every endpoint webhooks-saved holds, with its workflow"
  (for-each (lambda (row)
              (ignore-errors
               (lambda ()
                 (let ((opts (if (> (length row) 3) (list-ref row 3) '())))
                   (define-webhook! (car row) (list 'path (cadr row) 'token (caddr row)
                                                    'methods (plist-get opts 'methods)
                                                    'data (plist-get opts 'data)
                                                    'public (plist-get opts 'public)))
                   (when (plist-get opts 'workflow)
                     (webhook-attach-workflow! (car row) (string->symbol (plist-get opts 'workflow))))))))
            webhooks-saved))

(define (webhooks--keep! name)
  "(webhooks--keep! NAME) — write endpoint NAME and its workflow to webhooks-saved, or drop it when NAME is gone. An endpoint with a Scheme handler belongs to its code and is not kept"
  (let* ((hook (webhook-get name))
         (wf (webhook-workflow name))
         (rest (filter (lambda (row) (not (equal? (car row) name))) webhooks-saved)))
    (unless (and hook (plist-get hook 'handler))
      (customize-save! 'webhooks-saved
                       (if hook
                           (append rest (list (list name (plist-get hook 'path) (plist-get hook 'token)
                                                    (list 'methods (plist-get hook 'methods)
                                                          'data (plist-get hook 'data)
                                                          'public (plist-get hook 'public)
                                                          'workflow (if wf (symbol->string wf) #f)))))
                           rest)))))

(define (webhooks--blank? s) (or (not s) (equal? (string-trim s) "")))

(define-command "webhook-define" "Define a webhook endpoint that turns each request into an event, and keep it"
  (lambda ()
    (read-string "Webhook name: "
      (lambda (name)
        (unless (webhooks--blank? name)
          (read-string "Token (empty for none): "
            (lambda (token)
              (let ((name (string-trim name))
                    (token (if (webhooks--blank? token) #f (string-trim token))))
                (define-webhook! name (list 'token token))
                (webhooks--keep! name)
                (webhooks-refresh!)
                (message (string-append "webhook " name ": "
                                        (or (webhook-url name)
                                            (string-append (plist-get (webhook-get name) 'path)
                                                           ", M-x webhooks-start to listen"))))))))))))

(define (webhooks--delete! name)
  (webhook-detach-workflow! name)
  (webhook-remove! name)
  (webhooks--keep! name)
  (webhooks-refresh!)
  (message (string-append "webhook " name " removed")))

(define-command "webhook-delete" "Remove a webhook endpoint and forget it"
  (lambda ()
    (if (null? (registry-names 'webhook))
        (message "no webhooks defined")
        (completing-read "Delete webhook: " (registry-names 'webhook)
          (lambda (name) (when name (webhooks--delete! name)))
          'require-match #t))))

;; M-x webhooks: the endpoints as a list, and the verbs on them

(defface! 'webhooks-name 'fg "#26356b" 'weight "600")
(defface! 'webhooks-path 'fg "#7a5a1a")

(define *webhooks-buffer* "*webhooks*")

(define (webhooks-refresh!)
  (when (buffer-exists? *webhooks-buffer*) (list-refresh! *webhooks-buffer*)))

(define (webhooks--last name)
  (let ((es (event-log-newest (string-append "webhook:" name) 1)))
    (if (pair? es) (format-time (plist-get (car es) 'at) "%a %d %b %H:%M") "-")))

(define (webhooks--workflow-text name)
  (let ((h (webhook-workflow name)))
    (if (not h)
        "-"
        (let ((st (workflow-status (webhooks--workflow-name name))))
          (string-append (symbol->string h)
                         (if st (string-append " · " (format "~a" (plist-get st 'status))) " · stopped")
                         (if (and st (plist-get st 'last-error)) " · failing" ""))))))

(define (webhooks--cells buf name)
  (let ((hook (webhook-get name)))
    (if (not hook)
        (list (list name "webhooks-name") (list "" "faint") (list "" "faint")
              (list "" "faint") (list "" "faint") (list "" "faint") (list "" "faint"))
        (list (list name "webhooks-name")
              (list (plist-get hook 'path) "webhooks-path")
              (list (string-join (plist-get hook 'methods) ",") "dim")
              (list (if (plist-get hook 'token) "yes" "-") "dim")
              (list (if (plist-get hook 'public) "public" "local") "dim")
              (list (webhooks--last name) "dim")
              (list (if (plist-get hook 'handler) "Scheme handler" (webhooks--workflow-text name)) "default")))))

(define (webhooks--meta buf)
  (string-append (number->string (length (registry-names 'webhook))) " endpoints · "
                 (if (webhooks-running?)
                     (string-append "listening on " webhooks-host ":" (number->string webhooks-port)
                                    (cond ((webhooks-tunnel-up?) (string-append " · tunnel https://" webhooks-tunnel-host))
                                          (webhooks-tunnel-host " · tunnel down")
                                          (else "")))
                     "server stopped, s starts it")))

(define (webhooks--on-current fn)
  (let ((name (list-current *webhooks-buffer*)))
    (if name (fn name) (message "no webhook on this line"))))

(define (webhooks--said name what)
  (webhooks-refresh!)
  (message (string-append "webhook " name ": " what
                          (let ((hook (webhook-get name)))
                            (if (and hook (plist-get hook 'handler)) " (Scheme handler: not kept)" "")))))

(define (webhooks--methods text)
  (let ((ms (filter (lambda (m) (not (webhooks--blank? m)))
                    (map (lambda (m) (string-upcase (string-trim m)))
                         (string-split (or text "") ",")))))
    (if (null? ms) #f ms)))

(define-command "webhooks-edit" "Change the path, methods and token of the webhook on this line"
  (lambda ()
    (webhooks--on-current
      (lambda (name)
        (let ((hook (webhook-get name)))
          (read-string "Path: "
            (lambda (path)
              (read-string "Methods (comma separated): "
                (lambda (methods)
                  (read-string "Token (empty for none): "
                    (lambda (token)
                      (define-webhook! name
                        (list 'path (if (webhooks--blank? path) #f (string-trim path))
                              'methods (webhooks--methods methods)
                              'token (if (webhooks--blank? token) #f (string-trim token))
                              'peers (plist-get hook 'peers)
                              'data (plist-get hook 'data)
                              'public (plist-get hook 'public))
                        (plist-get hook 'handler))
                      (webhooks--keep! name)
                      (webhooks--said name "changed"))
                    'initial (or (plist-get hook 'token) "")))
                'initial (string-join (plist-get hook 'methods) ",")))
            'initial (plist-get hook 'path)))))))

(define-command "webhooks-attach-workflow" "Run a Scheme handler, as a workflow, on every request to the webhook on this line"
  (lambda ()
    (webhooks--on-current
      (lambda (name)
        (read-string "Workflow handler, called as (HANDLER KEY EVENTS): "
          (lambda (text)
            (unless (webhooks--blank? text)
              (let ((sym (string->symbol (string-trim text))))
                (if (not (boundp sym))
                    (message (string-append "no function named " (string-trim text)))
                    (begin (webhook-attach-workflow! name sym)
                           (webhooks--keep! name)
                           (webhooks--said name (string-append "workflow " (symbol->string sym))))))))
          'initial (let ((h (webhook-workflow name))) (if h (symbol->string h) "")))))))

(define-command "webhooks-history" "Show the requests the webhook on this line took, newest first"
  (lambda ()
    (webhooks--on-current
      (lambda (name)
        (events-list-open!)
        (events-list-set-topic! (string-append "webhook:" name))
        (list-mode-show! "events-mode")))))

(define-command "webhooks-detach-workflow" "Stop the workflow on the webhook on this line"
  (lambda ()
    (webhooks--on-current
      (lambda (name)
        (if (not (webhook-workflow name))
            (message (string-append "webhook " name " has no workflow"))
            (begin (webhook-detach-workflow! name)
                   (webhooks--keep! name)
                   (webhooks--said name "workflow stopped")))))))

(define-command "webhooks-remove" "Remove the webhook on this line and forget it"
  (lambda () (webhooks--on-current webhooks--delete!)))

(define-command "webhooks-copy-url" "Copy the URL of the webhook on this line"
  (lambda ()
    (webhooks--on-current
      (lambda (name)
        (let ((url (webhook-url name)))
          (if url
              (begin (kill-new url) (message (string-append "copied " url)))
              (message "the server is stopped, s starts it")))))))

(define-command "webhooks-toggle-public" "Let the webhook on this line answer through the tunnel, or keep it local"
  (lambda ()
    (webhooks--on-current
      (lambda (name)
        (let ((hook (webhook-get name)))
          (define-webhook! name
            (list 'path (plist-get hook 'path) 'methods (plist-get hook 'methods)
                  'token (plist-get hook 'token) 'peers (plist-get hook 'peers)
                  'data (plist-get hook 'data) 'public (not (plist-get hook 'public)))
            (plist-get hook 'handler))
          (webhooks--keep! name)
          (webhooks--said name (if (plist-get (webhook-get name) 'public) "is public" "is local")))))))

(define-command "webhooks-toggle-server" "Start the webhook server, or stop it"
  (lambda ()
    (if (webhooks-running?)
        (begin (webhooks-stop!) (customize-save! 'webhooks-enabled #f)
               (message "webhook server stopped"))
        (let ((url (webhooks-start!)))
          (customize-save! 'webhooks-enabled #t)
          (message (string-append "webhooks listen on " url))))
    (webhooks-refresh!)))

(define-command "webhooks-refresh" "Redraw the webhook list"
  (lambda () (webhooks-refresh!)))

(define-list-mode! "webhooks-mode"
  (list
    'doc (string-append
           "The webhook endpoints: path, methods, whether a token guards it, the last request, "
           "and the workflow that handles its events. c defines one, e edits the path, "
           "methods and token, w attaches a workflow handler, W stops it, k removes the "
           "endpoint, p makes it public through the tunnel or local again, y copies its URL, h or RET shows its request history, s starts or stops the server, g redraws, "
           "/ narrows, and q quits.")
    'buffer *webhooks-buffer*
    'transient #f
    'rows (lambda (buf) (registry-names 'webhook))
    'columns (lambda (buf)
               (list (list "webhook" 16) (list "path" 22) (list "methods" 10)
                     (list "token" 6) (list "reach" 7) (list "last request" 17) (list "workflow" #f)))
    'cells webhooks--cells
    'title (lambda (buf) "Webhooks")
    'meta webhooks--meta
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("c" "define") ("e" "edit") ("w" "workflow") ("k" "remove")
                ("p" "public") ("h" "history") ("s" "server") ("/" "filter") ("q" "quit")))
    'keys '(("c" "webhook-define") ("e" "webhooks-edit")
            ("w" "webhooks-attach-workflow") ("W" "webhooks-detach-workflow")
            ("k" "webhooks-remove") ("p" "webhooks-toggle-public") ("y" "webhooks-copy-url")
            ("h" "webhooks-history") ("RET" "webhooks-history")
            ("s" "webhooks-toggle-server") ("g" "webhooks-refresh")
            ("q" "quit-window"))))

(define-command "webhooks" "List the webhook endpoints: define, edit, attach workflows"
  (lambda () (list-mode-show! "webhooks-mode")))

(effects! '(write))
(public! 'define-webhook! "(define-webhook! NAME [OPTS] [HANDLER]) — define or replace webhook endpoint NAME. OPTS: 'path (default /hooks/NAME), 'methods (default POST only), 'token (checked against the x-webhook-token header or Authorization: Bearer), 'peers (the remote addresses allowed), 'data ('json: the event data is the JSON body alone), 'public (#t: it answers through the Cloudflare tunnel; else a tunneled request gets 404). HANDLER gets the request plist plus 'webhook and 'json, and answers a response plist, a body string, or anything else for ok. Without HANDLER each request becomes a webhook:NAME event")
(public! 'webhook-remove! "(webhook-remove! NAME) — drop webhook endpoint NAME")
(public! 'webhook-attach-workflow! "(webhook-attach-workflow! NAME HANDLER) — run (HANDLER KEY EVENTS) on every webhook:NAME event, as the workflow webhook-NAME; give HANDLER as a quoted name")
(public! 'webhook-detach-workflow! "(webhook-detach-workflow! NAME) — stop the workflow on webhook NAME")
(effects! '(read))
(public! 'webhook-get "(webhook-get NAME) — the webhook endpoint plist named NAME, or #f")
(public! 'webhook-list "(webhook-list) — every webhook endpoint as (NAME METHODS PATH)")
(public! 'webhook-url "(webhook-url NAME) — the URL of webhook NAME on the running server, or #f")
(public! 'webhooks-tunnel-up? "(webhooks-tunnel-up?) — #t while cloudflared carries the tunnel to webhooks-tunnel-host")
(public! 'webhooks-running? "(webhooks-running?) — #t while the webhook server listens")
(public! 'webhook-workflow "(webhook-workflow NAME) — the handler of the workflow attached to webhook NAME, or #f")
(effects! '(write external))
(public! 'webhooks-start! "(webhooks-start!) — start the webhook server on webhooks-host and webhooks-port; answers its URL")
(public! 'webhooks-stop! "(webhooks-stop!) — stop the webhook server; the endpoints stay defined")

(defrecipe! "define a webhook endpoint"
  "(define-webhook! {{name}} (list 'token {{token}}) (lambda (request) (plist-get request 'json)))"
  (list (list 'name "Webhook name: ") (list 'token "Shared token: ")))

(webhooks--define-saved!)

(when webhooks-enabled
  (ignore-errors (lambda () (webhooks-start!))))
