;;; sentry-test.scm --- packages/sentry.scm, the read-only client, offline.
;;;
;;; Every test replaces the transport seam. No test reads Doppler or
;;; reaches Sentry.
;;;
;;; Three tests stay in ExUnit. They drive RET, n, p, a, R and y through
;;; KeyDispatch, which is the path the GUI uses and is what a test of an
;;; interaction is for.

(domain! 'testing)
(effects! '(write))

;; The seams are globals. Every test puts back what it found: the next
;; test reads the same ones, and the live editor reaches the network
;; through them.
(define (t--sentry-with-transport fetch thunk)
  (let ((saved *sentry-transport*))
    (set! *sentry-transport* fetch)
    (let ((out (thunk)))
      (set! *sentry-transport* saved)
      out)))

(deftest 'the-sentry-defaults-point-at-the-production-project
  "the org, the project and the environment a call assumes"
  (lambda ()
    (check-equal! (list sentry-org sentry-project sentry-environment)
                  '("svs-recruiting" "ats-ash" "prod") "the defaults")))

(deftest 'an-issue-search-encodes-its-filters-and-caps-its-limit
  "the query, the environment and the period ride the URL; the limit is ours"
  (lambda ()
    (let ((url ""))
      (t--sentry-with-transport
        (lambda (u) (set! url u) "[]\n200")
        (lambda () (sentry-list-issues "is:unresolved assigned:me" "prod" "7d" 500)))
      (check-contains! url "/api/0/projects/svs-recruiting/ats-ash/issues/" "the path")
      (check-contains! url "query=is%3Aunresolved%20assigned%3Ame" "the encoded query")
      (check-contains! url "environment=prod" "the environment")
      (check-contains! url "statsPeriod=7d" "the period")
      (check-contains! url "per_page=50" "the capped limit"))))

(deftest 'http-failures-have-one-safe-result-shape
  "the status is the message, and the body never reaches the reader"
  (lambda ()
    (let ((reply (t--sentry-with-transport
                   (lambda (u) "private response body\n403")
                   (lambda () (sentry-list-issues)))))
      (check-true! (plist-get reply 'errors) "the reply carries errors")
      (check-contains! (value->string reply) "HTTP 403" "the status")
      (check-false! (string-contains? (value->string reply) "private response body")
                    "and not the body"))))

(deftest 'the-client-enforces-its-row-limit-when-sentry-returns-more
  "a server that ignores per_page does not get to fill the buffer"
  (lambda ()
    (let* ((rows (t--sentry-with-transport
                   (lambda (u) "[{\"id\":\"1\"},{\"id\":\"2\"},{\"id\":\"3\"}]\n200")
                   (lambda () (sentry-list-issues "" "prod" "24h" 2))))
           (ids (map (lambda (r) (plist-get r 'id)) rows)))
      (check-equal! ids '("1" "2") "two rows, in order"))))

(deftest 'the-issue-detail-puts-the-exception-first-and-keeps-the-raw-json
  "the reader sees the error, and the whole record is still there to read"
  (lambda ()
    (let ((text (sentry--issue-text
                  (list 'shortId "ATS-1"
                        'title ""
                        'status "unresolved"
                        'metadata
                        (list 'type "RuntimeError"
                              'value "credits exhausted"
                              'secret "visible-in-raw")))))
      (check-contains! text "ATS-1  RuntimeError" "the heading")
      (check-contains! text "Exception\ncredits exhausted" "the exception first")
      (check-contains! text "Raw issue JSON" "the raw section")
      (check-contains! text "visible-in-raw" "which holds everything")
      (check-false! (string-contains? text "<!doctype html>") "and no HTML"))))

(deftest 'the-sentry-api-declares-its-domain-and-effects
  "a read that reaches the network says both"
  (lambda ()
    (let ((entry (catalog-entry 'function "sentry-list-issues")))
      (check-equal! (plist-get entry 'domain) "sentry" "the domain")
      (check-equal! (plist-get entry 'effects) '("read" "external") "the effects"))
    (check-equal! (plist-get (catalog-entry 'command "sentry") 'effects)
                  '("write" "external") "the command writes a buffer too")))
