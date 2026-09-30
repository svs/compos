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
;;; as topic webhook:NAME, kind received.

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
  'group 'webhooks 'type 'sexp)

(defcustom 'webhooks-enabled #f
  "Start the webhook server when this package loads."
  'group 'webhooks 'type 'boolean)

;; NAME -> the endpoint plist: name path methods token peers handler
(define *webhooks* '())
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
  (let ((hit (assoc name *webhooks*))) (and hit (cdr hit))))

(define (webhook-list)
  "(webhook-list) — every endpoint as (NAME METHODS PATH)"
  (map (lambda (e) (list (car e) (plist-get (cdr e) 'methods) (plist-get (cdr e) 'path)))
       *webhooks*))

(define (webhook-url name)
  "(webhook-url NAME) — the URL of endpoint NAME on the running server, or #f"
  (let ((hook (webhook-get name)))
    (and hook *webhooks-server*
         (string-append (plist-get *webhooks-server* 'url) (plist-get hook 'path)))))

(define (webhooks-running?)
  "(webhooks-running?) — #t while the webhook server listens"
  (and *webhooks-server* #t))

(effects! '(write))

(define (webhooks--publish! hook request json)
  (event-publish! (string-append "webhook:" (plist-get hook 'name)) 'received
                  (list 'method (plist-get request 'method)
                        'path (plist-get request 'path)
                        'query (plist-get request 'query)
                        'headers (plist-get request 'headers)
                        'body (plist-get request 'body)
                        'json json
                        'remote-address (plist-get request 'remote-address))))

(define (webhooks--handle request)
  "(webhooks--handle REQUEST) — route one request to its endpoint and answer the response"
  (let* ((path (plist-get request 'path))
         (hit (filter (lambda (e) (equal? (plist-get (cdr e) 'path) path)) *webhooks*))
         (hook (and (pair? hit) (cdr (car hit)))))
    (cond ((not hook) (webhooks--reply 404 "not found"))
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
  "(define-webhook! NAME [OPTS] [HANDLER]) — define or replace endpoint NAME; OPTS is a plist of 'path (default /hooks/NAME), 'methods (default POST only), 'token and 'peers"
  (let* ((opts (or opts '()))
         (path (or (plist-get opts 'path) (string-append "/hooks/" name)))
         (hook (list 'name name
                     'path (if (string-prefix? "/" path) path (string-append "/" path))
                     'methods (or (plist-get opts 'methods) (list "POST"))
                     'token (plist-get opts 'token)
                     'peers (plist-get opts 'peers)
                     'handler handler))
         (clash (filter (lambda (e) (and (not (equal? (car e) name))
                                         (equal? (plist-get (cdr e) 'path) (plist-get hook 'path))))
                        *webhooks*)))
    (if (pair? clash)
        (error (string-append "webhook " (car (car clash)) " already takes " (plist-get hook 'path)))
        (begin (set! *webhooks* (append (filter (lambda (e) (not (equal? (car e) name))) *webhooks*)
                                         (list (cons name hook))))
               name))))

(define (webhook-remove! name)
  "(webhook-remove! NAME) — drop endpoint NAME; #t when it was there"
  (let ((had (and (webhook-get name) #t)))
    (set! *webhooks* (filter (lambda (e) (not (equal? (car e) name))) *webhooks*))
    had))

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
  (plist-get *webhooks-server* 'url))

(define (webhooks-stop!)
  "(webhooks-stop!) — stop the webhook server; the endpoints stay defined"
  (web-server-stop! "webhooks")
  (set! *webhooks-server* #f)
  #t)

(define-command "webhooks-start" "Start the webhook server"
  (lambda () (message (string-append "webhooks on " (webhooks-start!)))))

(define-command "webhooks-stop" "Stop the webhook server"
  (lambda () (webhooks-stop!) (message "webhooks off")))

(define-command "webhooks-list" "Say every webhook endpoint and where it listens"
  (lambda ()
    (message
     (if (null? *webhooks*)
         "no webhooks defined"
         (string-join
          (map (lambda (row)
                 (string-append (car row) "  " (string-join (cadr row) ",") " "
                                (or (webhook-url (car row)) (caddr row))))
               (webhook-list))
          "\n")))))

(effects! '(write))

(define (webhooks--define-saved!)
  "(webhooks--define-saved!) — define every endpoint webhooks-saved holds"
  (for-each (lambda (row)
              (ignore-errors
               (lambda () (define-webhook! (car row) (list 'path (cadr row) 'token (caddr row))))))
            webhooks-saved))

(define (webhooks--blank? s) (or (not s) (equal? (string-trim s) "")))

(define-command "webhook-define" "Define a webhook endpoint that turns each request into an event, and keep it"
  (lambda ()
    (read-string "Webhook name: "
      (lambda (name)
        (unless (webhooks--blank? name)
          (read-string "Token (empty for none): "
            (lambda (token)
              (let* ((name (string-trim name))
                     (token (if (webhooks--blank? token) #f (string-trim token)))
                     (path (string-append "/hooks/" name)))
                (define-webhook! name (list 'path path 'token token))
                (customize-save! 'webhooks-saved
                                 (append (filter (lambda (row) (not (equal? (car row) name))) webhooks-saved)
                                         (list (list name path token))))
                (message (string-append "webhook " name ": "
                                        (or (webhook-url name)
                                            (string-append path ", M-x webhooks-start to listen"))))))))))))

(define-command "webhook-delete" "Remove a webhook endpoint and forget it"
  (lambda ()
    (if (null? *webhooks*)
        (message "no webhooks defined")
        (completing-read "Delete webhook: " (map car *webhooks*)
          (lambda (name)
            (when name
              (webhook-remove! name)
              (customize-save! 'webhooks-saved
                               (filter (lambda (row) (not (equal? (car row) name))) webhooks-saved))
              (message (string-append "webhook " name " removed"))))
          'require-match #t))))

(effects! '(write))
(public! 'define-webhook! "(define-webhook! NAME [OPTS] [HANDLER]) — define or replace webhook endpoint NAME. OPTS: 'path (default /hooks/NAME), 'methods (default POST only), 'token (checked against the x-webhook-token header or Authorization: Bearer), 'peers (the remote addresses allowed). HANDLER gets the request plist plus 'webhook and 'json, and answers a response plist, a body string, or anything else for ok. Without HANDLER each request becomes a webhook:NAME event")
(public! 'webhook-remove! "(webhook-remove! NAME) — drop webhook endpoint NAME")
(effects! '(read))
(public! 'webhook-get "(webhook-get NAME) — the webhook endpoint plist named NAME, or #f")
(public! 'webhook-list "(webhook-list) — every webhook endpoint as (NAME METHODS PATH)")
(public! 'webhook-url "(webhook-url NAME) — the URL of webhook NAME on the running server, or #f")
(public! 'webhooks-running? "(webhooks-running?) — #t while the webhook server listens")
(effects! '(write external))
(public! 'webhooks-start! "(webhooks-start!) — start the webhook server on webhooks-host and webhooks-port; answers its URL")
(public! 'webhooks-stop! "(webhooks-stop!) — stop the webhook server; the endpoints stay defined")

(defrecipe! "define a webhook endpoint"
  "(define-webhook! {{name}} (list 'token {{token}}) (lambda (request) (plist-get request 'json)))"
  (list (list 'name "Webhook name: ") (list 'token "Shared token: ")))

(webhooks--define-saved!)

(when webhooks-enabled
  (ignore-errors (lambda () (webhooks-start!))))
