;;; endpoint.scm --- long-lived connections: registry, event fan-out, status.
;;;
;;; Policy over the Compos.Core.Endpoint mechanism. An endpoint is one
;;; named connection to a program or a network service that stays open
;;; across many requests, so a caller pays the startup cost once.
;;;
;;; A client for a database, a REPL, a shell, or a line-oriented network
;;; service is a Scheme package over one endpoint. The Elixir side owns
;;; the transport, the framing, and the request queue. This package owns
;;; the registry, the event fan-out, and what a caller sees.

(category! 'system)
(domain! 'endpoints)
(effects! '(write external execute))

;;; --- registry ----------------------------------------------------------------

;; The registry table endpoint: — a spec a caller registered under a name, so a
;; reconnect repeats it and nobody stores connection details twice.
(define (endpoint-register! name spec)
  (registry-register! 'endpoint name spec))

(define (endpoint-spec name)
  (registry-lookup 'endpoint name))

;; Every name a package registered. A package that manages the programs
;; behind these connections - the model list is one - reads the registry
;; here instead of keeping a second list of its own.
(define (endpoint-names) (registry-names 'endpoint))

(define (endpoint-connected? name)
  (let ((d (conn-detail 'endpoint name)))
    (and d (equal? (plist-get d 'status) "ready"))))

;; Start a registered endpoint once. A live connection is reused, which
;; is the whole point: the caller asks for the name, not for a socket.
;; Which fields of an endpoint spec may carry a "@VAR" reference. 'env
;; is the subprocess environment, the same shape MCP uses, and 'args
;; resolves element by element because joining them would build one
;; argument out of several.
(define endpoint-secret-fields
  '(env plist args each command value host value))

(define (endpoint-resolve-spec spec) (spec-resolve spec endpoint-secret-fields))

(define (endpoint-ensure! name)
  (let ((spec (endpoint-spec name)))
    (cond ((not spec) (error (string-append "endpoint: no spec registered for " name)))
          ((endpoint-connected? name) name)
          (else (endpoint-start! name (endpoint-resolve-spec spec)) name))))

(define (endpoint-restart! name)
  (endpoint-stop! name)
  (endpoint-ensure! name))

;;; --- a JSON line daemon ------------------------------------------------------
;;; The convention a local daemon behind a pipe follows: one JSON object a
;;; request, one a reply, and a reply that carries ok. The answer reads
;;; back as the plist an http reply answers, so a caller reads one shape
;;; whether the program it asks is a server, a socket, or this pipe.

(define (endpoint-json-reply ok frames)
  (let* ((text (cond ((and ok (pair? frames)) (string-trim (car frames)))
                     ((string? frames) (string-trim frames))
                     (else "")))
         (json (if (equal? text "") #f (json-parse text))))
    (cond ((not ok)
           (list 'ok #f 'status #f 'body text
                 'error (if (equal? text "") "the daemon gave no answer" text)))
          ((not (pair? json))
           (list 'ok #f 'status #f 'body text 'error "the daemon answered no JSON"))
          ((plist-get json 'ok)
           (list 'ok #t 'status 200 'body text 'json json))
          (else
           (list 'ok #f 'status #f 'body text
                 'error (or (plist-get json 'error) "the daemon refused"))))))

(define (endpoint-ask-json name req timeout k)
  (if (not (endpoint-connected? name))
      (k (list 'ok #f 'status #f 'body ""
               'error (string-append name ": the daemon is not running")))
      (endpoint-ask name (json-encode req) #f timeout
        (lambda (ok frames) (k (endpoint-json-reply ok frames))))))

;;; --- events ------------------------------------------------------------------

;; the endpoint event handler is a single slot; this package owns it and fans out
;; to the keyed hook: (add-hook! (list 'endpoint-event NAME) FN), FN gets
;; (NAME KIND TEXT), and the same NAME replaces. Without this, two
;; packages that both watch endpoints silently clobber each other, and
;; the second one loaded is the only one that ever runs.
(on-event! 'endpoint
  (lambda (name kind text)
    (run-hook-with-args 'endpoint-event name kind text)))

;;; --- catalog -----------------------------------------------------------------

(public! 'endpoint-register!
  "(endpoint-register! NAME SPEC) — name a long-lived connection to a database, a REPL, a subprocess, or a tcp socket; SPEC has 'command 'args 'env 'cd 'stderr, or 'host 'port, plus 'framing \"line\" \"delimiter\" \"content-length\" \"length\" or \"raw\"")
(public! 'endpoint-framings
  "framing \"line\" splits on newlines; \"delimiter\" on 'delimiter; \"content-length\" reads the LSP header; \"length\" reads a binary length-prefixed protocol with 'length-width 'length-prefix 'length-endian 'length-counts; \"raw\" passes chunks through")
(public! 'endpoint-ensure!
  "(endpoint-ensure! NAME) — open the registered persistent connection or socket once and reuse it; a query pays no reconnect cost")
(public! 'endpoint-restart!
  "(endpoint-restart! NAME) — close the connection and open it again from its registered spec")
(public! 'endpoint-spec
  "(endpoint-spec NAME) — the spec registered for NAME, or #f")
(public! 'endpoint-names
  "(endpoint-names) — every registered connection name, the registry a manager reads")
(public! 'endpoint-ask-json
  "(endpoint-ask-json NAME REQ TIMEOUT K) — ask a JSON-line daemon one request; K gets the reply as the plist an http reply answers: ok, status, body, json, error")
(public! 'endpoint-resolve-spec
  "(endpoint-resolve-spec SPEC) — resolve the \"@VAR\" references in an endpoint spec before it leaves for Elixir")
(public! 'endpoint-connected?
  "(endpoint-connected? NAME) — #t when the client connection or socket is open and ready to run a query")

;; The primitives underneath. They are Elixir builtins, so the catalog
;; only learns them here; without these lines a package author searching
;; for a database or a subprocess connection finds nothing.
(public! 'endpoint-start!
  "(endpoint-start! NAME SPEC) — spawn a program or connect a tcp socket, and keep that long-lived connection open for many queries")
(public! 'endpoint-stop!
  "(endpoint-stop! NAME) — close the connection NAME")
(public! 'endpoint-ask
  "(endpoint-ask NAME TEXT UNTIL [TIMEOUT] CB) — send a query and collect the result frames up to the sentinel UNTIL; CB gets (OK FRAMES)")
(public! 'endpoint-send!
  "(endpoint-send! NAME TEXT) — write one frame to the connection and do not wait")

(effects! '(read external))
(defrecipe! "open a client connection to a database, a repl, or a tcp socket"
  "(endpoint-register! {{name}} '(command {{command}} framing \"line\"))"
  (list (list 'name "Connection name: ") (list 'command "Program to run: ")))
(defrecipe! "see the open connections"
  "(conn-list 'endpoint)" '())
(defrecipe! "see why a connection will not start"
  "(conn-log 'endpoint {{name}})"
  (list (list 'name "Connection name: ")))
