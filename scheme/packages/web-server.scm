;;; web-server.scm --- programmable inbound HTTP servers.
;;;
;;; Elixir and Bandit own listeners, HTTP parsing, limits, and response writes.
;;; Scheme handlers own routes and all callback or webhook policy.

(category! 'system)
(domain! 'web-servers)
(effects! '(write external))

(public! 'web-server-start!
  "(web-server-start! NAME SPEC HANDLER) — start an HTTP callback or webhook server; SPEC has 'host, 'port, and 'max-body")
(public! 'web-server-stop!
  "(web-server-stop! NAME) — stop the named HTTP server; stopping a missing server succeeds")
