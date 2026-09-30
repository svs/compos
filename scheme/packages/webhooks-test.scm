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
