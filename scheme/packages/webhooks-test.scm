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

(deftest 'webhooks-saved-endpoints-come-back
  "an endpoint webhook-define kept is defined again from webhooks-saved"
  (lambda ()
    (let ((saved webhooks-saved))
      (set! webhooks-saved (list (list "zz-test-saved" "/hooks/zz-test-saved" "t0k")))
      (webhooks--define-saved!)
      (set! webhooks-saved saved))
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
                                       (list 'methods (list "POST" "PUT")
                                             'workflow "webhooks-test--handler"))))
      (webhooks--define-saved!)
      (set! webhooks-saved saved))
    (check-true! (equal? (list "POST" "PUT") (plist-get (webhook-get "zz-test-wf") 'methods))
                 "it keeps its methods")
    (check-true! (eq? 'webhooks-test--handler (webhook-workflow "zz-test-wf")) "it keeps its workflow")
    (check-true! (member "webhook-zz-test-wf" (workflow-names)) "the workflow runs")
    (check-true! (string-prefix? "webhooks-test--handler"
                                 (car (list-ref (webhooks--cells #f "zz-test-wf") 5)))
                 "the row names the handler")
    (webhook-detach-workflow! "zz-test-wf")
    (check-false! (webhook-workflow "zz-test-wf") "detach forgets the workflow")
    (webhook-remove! "zz-test-wf")))
