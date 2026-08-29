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

(package! 'endpoint)
(category! 'system)
(domain! 'endpoints)
(effects! '(write external execute))

;;; --- registry ----------------------------------------------------------------

;; ((name spec) ...) — a spec a caller registered under a name, so a
;; reconnect repeats it and nobody stores connection details twice.
(define *endpoint-registry* '())

(define (endpoint-register! name spec)
  (set! *endpoint-registry*
    (cons (list name spec)
          (remove (lambda (e) (equal? (car e) name)) *endpoint-registry*)))
  name)

(define (endpoint-spec name)
  (let ((e (assoc name *endpoint-registry*)))
    (and e (cadr e))))

(define (endpoint-connected? name)
  (let ((d (endpoint-detail name)))
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

;;; --- events ------------------------------------------------------------------

;; endpoint-on-event! is a single slot; this package owns it and fans out.
;; Add a listener with (on-endpoint-event! NAME FN) — same name replaces.
;; Without this, two packages that both watch endpoints silently clobber
;; each other, and the second one loaded is the only one that ever runs.
(define *endpoint-event-handlers* '())

(define (on-endpoint-event! name fn)
  (set! *endpoint-event-handlers*
    (cons (list name fn)
          (remove (lambda (e) (equal? (car e) name)) *endpoint-event-handlers*))))

(endpoint-on-event!
  (lambda (name kind text)
    (for-each (lambda (e) ((cadr e) name kind text)) *endpoint-event-handlers*)))

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
(public! 'endpoint-resolve-spec
  "(endpoint-resolve-spec SPEC) — resolve the \"@VAR\" references in an endpoint spec before it leaves for Elixir")
(public! 'endpoint-connected?
  "(endpoint-connected? NAME) — #t when the client connection or socket is open and ready to run a query")
(public! 'on-endpoint-event!
  "(on-endpoint-event! NAME FN) — add a named listener for (NAME KIND TEXT) unsolicited frames")

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
(public! 'endpoint-list
  "(endpoint-list) — every client connection this editor opened, as (name status transport framing queued)")
(public! 'endpoint-detail
  "(endpoint-detail NAME) — a status plist for one connection, or #f when it never started")
(public! 'endpoint-log
  "(endpoint-log NAME) — the frames both ways as ((time dir text) ...), oldest first; read this when a connection will not start")

(effects! '(read external))
(defrecipe! "open a client connection to a database, a repl, or a tcp socket"
  "(endpoint-register! {{name}} '(command {{command}} framing \"line\"))"
  (list (list 'name "Connection name: ") (list 'command "Program to run: ")))
(defrecipe! "see the open connections"
  "(endpoint-list)" '())
(defrecipe! "see why a connection will not start"
  "(endpoint-log {{name}})"
  (list (list 'name "Connection name: ")))
