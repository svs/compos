;;; webhooks-test.scm --- routing tests for webhook endpoints; no port opens.

(domain! 'testing)
(effects! '(write))

(define (webhooks-test--request method path &optional headers body)
  (list 'method method 'path path 'query "" 'headers (or headers '())
        'body (or body "") 'remote-address "127.0.0.1"))

(define (webhooks-test--status response) (plist-get response 'status))

(deftest 'webhooks-route-by-path-method-and-token
  "a request reaches its endpoint only on its path, with its method and token"
  (lambda ()
    (define-webhook! "zz-test-hook" (list 'token "t0k")
      (lambda (request) (plist-get (plist-get request 'json) 'action)))
    (let ((json '(("content-type" "application/json")))
          (auth '(("content-type" "application/json") ("x-webhook-token" "t0k"))))
      (check-true! (equal? 404 (webhooks-test--status (webhooks--handle (webhooks-test--request "POST" "/hooks/nope"))))
                   "an unknown path is 404")
      (check-true! (equal? 405 (webhooks-test--status (webhooks--handle (webhooks-test--request "GET" "/hooks/zz-test-hook"))))
                   "a method the endpoint does not take is 405")
      (check-true! (equal? 401 (webhooks-test--status (webhooks--handle (webhooks-test--request "POST" "/hooks/zz-test-hook" json "{}"))))
                   "a missing token is 401")
      (let ((ok (webhooks--handle (webhooks-test--request "POST" "/hooks/zz-test-hook" auth "{\"action\":\"opened\"}"))))
        (check-true! (equal? 200 (webhooks-test--status ok)) "the right token is 200")
        (check-true! (equal? "opened" (plist-get ok 'body)) "the handler reads the parsed JSON"))
      (check-true! (equal? 200 (webhooks-test--status
                                (webhooks--handle (webhooks-test--request "POST" "/hooks/zz-test-hook"
                                                                          '(("authorization" "Bearer t0k")) ""))))
                   "a bearer token is accepted"))
    (webhook-remove! "zz-test-hook")
    (check-false! (webhook-get "zz-test-hook") "remove drops the endpoint")))

(deftest 'webhooks-refuse-a-taken-path
  "two endpoints may not share one path"
  (lambda ()
    (define-webhook! "zz-test-a" (list 'path "/zz-shared"))
    (check-false! (ignore-errors (lambda () (define-webhook! "zz-test-b" (list 'path "/zz-shared"))))
                  "the second endpoint on a path is refused")
    (webhook-remove! "zz-test-a")))

(deftest 'webhooks-json-data-is-the-payload
  "an endpoint with 'data 'json publishes the parsed body alone as the event's data"
  (lambda ()
    (define-webhook! "zz-test-json" (list 'data 'json))
    (webhooks--handle (webhooks-test--request "POST" "/hooks/zz-test-json"
                                              '(("content-type" "application/json"))
                                              "{\"kind\":\"transition\",\"application_id\":\"a1\"}"))
    (let ((es (event-log-newest "webhook:zz-test-json" 1)))
      (check-true! (pair? es) "the request is an event")
      (check-true! (equal? "a1" (plist-get (plist-get (car es) 'data) 'application_id))
                   "the data is the JSON body")
      (check-false! (plist-get (plist-get (car es) 'data) 'headers) "the headers stay out"))
    (webhook-remove! "zz-test-json")))

(deftest 'webhooks-only-public-endpoints-answer-the-tunnel
  "a request through the tunnel reaches a public endpoint; a local one answers it 404"
  (lambda ()
    (define-webhook! "zz-test-local" '())
    (define-webhook! "zz-test-public" (list 'public #t))
    (let ((tunneled '(("cf-ray" "8f00-DXB"))))
      (check-true! (equal? 404 (webhooks-test--status (webhooks--handle (webhooks-test--request "POST" "/hooks/zz-test-local" tunneled ""))))
                   "a local endpoint is 404 through the tunnel")
      (check-true! (equal? 200 (webhooks-test--status (webhooks--handle (webhooks-test--request "POST" "/hooks/zz-test-local"))))
                   "a local endpoint answers on this machine")
      (check-true! (equal? 200 (webhooks-test--status (webhooks--handle (webhooks-test--request "POST" "/hooks/zz-test-public" tunneled ""))))
                   "a public endpoint answers through the tunnel"))
    (webhook-remove! "zz-test-local")
    (webhook-remove! "zz-test-public")))

(deftest 'webhooks-saved-endpoints-come-back
  "a saved endpoint is defined again when custom.scm sets webhooks-saved, after the package loaded"
  (lambda ()
    (with-custom 'webhooks-saved (list (list "zz-test-saved" "/hooks/zz-test-saved" "t0k"))
      (lambda () #t))
    (let ((hook (webhook-get "zz-test-saved")))
      (check-true! hook "the saved endpoint is defined")
      (check-true! (equal? "t0k" (plist-get hook 'token)) "it keeps its token"))
    (webhook-remove! "zz-test-saved")))

(define (webhooks-test--handler key events) #t)

(deftest 'webhooks-saved-workflow-comes-back
  "a kept endpoint brings back its methods and its workflow, and the list row says the handler"
  (lambda ()
    (let ((saved webhooks-saved))
      (set! webhooks-saved (list (list "zz-test-wf" "/hooks/zz-test-wf" #f
                                       (list 'methods (list "POST" "PUT") 'data 'json 'public #t
                                             'workflow "webhooks-test--handler"))))
      (webhooks--define-saved!)
      (set! webhooks-saved saved))
    (check-true! (equal? (list "POST" "PUT") (plist-get (webhook-get "zz-test-wf") 'methods))
                 "it keeps its methods")
    (check-true! (eq? 'json (plist-get (webhook-get "zz-test-wf") 'data)) "it keeps its data shape")
    (check-true! (plist-get (webhook-get "zz-test-wf") 'public) "it stays public")
    (check-true! (eq? 'webhooks-test--handler (webhook-workflow "zz-test-wf")) "it keeps its workflow")
    (check-true! (member "webhook-zz-test-wf" (workflow-names)) "the workflow runs")
    (check-true! (string-prefix? "webhooks-test--handler"
                                 (car (list-ref (webhooks--cells #f "zz-test-wf") 6)))
                 "the row names the handler")
    (webhook-detach-workflow! "zz-test-wf")
    (check-false! (webhook-workflow "zz-test-wf") "detach forgets the workflow")
    (webhook-remove! "zz-test-wf")))

(deftest 'webhooks-page-shows-config-and-requests
  "an endpoint's page shows its config, then the requests it took, newest first"
  (lambda ()
    ;; a name of its own each run: the test log keeps the events of earlier runs
    (let* ((name (string-append "zz-test-page-" (number->string (monotonic-ms))))
           (page (string-append "*" name "*")))
      (define-webhook! name (list 'token "t0k" 'data 'json))
      (event-publish! (string-append "webhook:" name) 'received (list 'kind "first_kind" 'summary "the older one"))
      (event-publish! (string-append "webhook:" name) 'received (list 'kind "second_kind" 'source "fireflies" 'summary "the newer one"))
      (let ((text (webhooks--detail-text name)))
        (check-true! (string-contains? text (string-append "/hooks/" name)) "it shows the path")
        (check-true! (string-contains? text "token       required") "it says a token guards it")
        (check-true! (string-contains? text "second_kind · fireflies") "it shows a request's kind and source")
        (check-true! (< (string-index text "the newer one") (string-index text "the older one"))
                     "the newest request comes first"))
      (buffer-create page)
      (buffer-set-local! page 'webhook-name name)
      (let ((rows (webhooks--page-rows page)))
        (check-equal! (plist-get (cadr (car rows)) 'data) (list 'kind "second_kind" 'source "fireflies" 'summary "the newer one")
                      "the page's first row is the newest request")
        (check-equal! (length (filter webhooks--request-row? rows)) 2 "each request is a row")
        (check-true! (assoc "token" (map cadr (filter (lambda (r) (not (webhooks--request-row? r))) rows)))
                     "the settings are rows too"))
      (buffer-kill! page)
      (webhook-remove! name))))
