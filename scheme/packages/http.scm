;;; http.scm --- HTTP requests from Scheme: one door, and no shell.
;;;
;;; (http-get "https://example.com/api") answers one plist:
;;;
;;;   (ok #t status 200 headers (content-type "application/json")
;;;    body "..." json (id 7))
;;;
;;; Read it with http-ok?, http-status, http-body, http-json and
;;; http-header. Every failure answers the same shape with ok #f and a
;;; line under 'error, so one caller reads one thing: a refused
;;; connection, a URL with no host and a 500 are not three different
;;; kinds of return value. Nothing here throws.
;;;
;;; A header value may be a key reference, resolved the moment the
;;; request leaves:
;;;
;;;   (http-get url '(headers (authorization ("Bearer " "@SENTRY_TOKEN"))))
;;;
;;; There is no shell, so there is no quoting to get wrong, and a token
;;; is never in a command line or in a temporary config file. graphql.scm,
;;; sentry.scm, feeds.scm, notmuch.scm and package.scm each built that by
;;; hand around curl. They still do: they move over one at a time.
;;;
;;; A body is a string, or a plist that becomes JSON:
;;;
;;;   (http-post url '(name "ada"))
;;;   (http-post url "one=two" '(headers (content-type "text/plain")))
;;;
;;; The plain forms wait, and hold the calling lane for up to
;;; http-timeout seconds. Pass a callback last and the request runs off
;;; the lane instead:
;;;
;;;   (http-get url '() (lambda (reply) (message (http-body reply))))

(domain! 'web)
(effects! '(read external))

(defgroup 'http "HTTP: the requests the editor makes to the web.")

(defcustom 'http-timeout 15
  "Seconds to wait for an HTTP response in the waiting form." 'group 'http)

(defcustom 'http-user-agent "compos"
  "The User-Agent the editor names itself with." 'group 'http)

(defcustom 'http-max-bytes 8000000
  "The most bytes of one response body the editor keeps." 'group 'http)

;;; --- reading an answer ----------------------------------------------------------

;; plist-get stops the interpreter when it is handed #f, and these read a
;; reply that a caller did not check the shape of first.
(define (http--text v)
  (if (symbol? v) (symbol->string v) v))

(define (http--first-line s)
  (if (string? s)
      (let ((line (string-trim (car (string-split s "\n")))))
        (if (> (string-length line) 200) (substring line 0 200) line))
      ""))

(define (http-ok? reply) (if (plist-get reply 'ok) #t #f))

(define (http-status reply) (plist-get reply 'status))

(define (http-body reply) (or (plist-get reply 'body) ""))

;; The parsed JSON of a JSON answer, or #f. The body is always the bytes
;; that arrived, so nothing needs to parse them a second time.
(define (http-json reply) (plist-get reply 'json))

(define (http-error reply) (plist-get reply 'error))

;; Header names arrive lower-cased, the way HTTP/2 writes them, so a
;; caller asking for Content-Type means content-type.
(define (http-header reply name)
  (plist-get (plist-get reply 'headers)
             (string->symbol (string-downcase (http--text name)))))

;; One line for a person or a log: what went wrong, or #f when nothing
;; did. A server that refuses often answers in HTML, and "HTTP 401" reads
;; better than the first two thousand characters of a login page.
(define (http-message reply)
  (cond ((http-ok? reply) #f)
        ((http-error reply) (http-error reply))
        (else (string-append "HTTP "
                             (number->string (or (http-status reply) 0))
                             ": " (http--first-line (http-body reply))))))

;;; --- making a request -----------------------------------------------------------

(define (http--opts opts) (if (pair? opts) opts '()))

;; The policy of one request lives here: the verb, redirects and the
;; waits. raw-http-request sends what it is given and decides nothing.
;; A wait the caller wrote that is not a positive whole number of
;; milliseconds falls back to the default, as it did in the core.
(define http--methods '("get" "post" "put" "patch" "delete" "head" "options"))

(define (http--wait v default) (if (and (integer? v) (> v 0)) v default))

(define (http--method o)
  (let ((m (plist-get o 'method)))
    (if (or (not m) (equal? m "")) "get" (string-downcase (http--text m)))))

(define (http-request url &optional opts k)
  (let* ((o (http--opts opts))
         (k (if (procedure? opts) opts k))
         (method (http--method o))
         (full (append (list 'method method
                             'timeout (http--wait (plist-get o 'timeout) (if k 120000 15000))
                             'connect-timeout (http--wait (plist-get o 'connect-timeout) 10000))
                       o
                       (list 'redirect #t))))
    (cond ((not (member method http--methods))
           (let ((r (list 'ok #f 'status #f 'headers '() 'body ""
                          'error (string-append "Unsupported HTTP method: " method))))
             (if k (k r) r)))
          (k (raw-http-request url full k))
          (else (raw-http-request url full)))))

;; A server that refuses an unnamed client is common enough that the
;; editor names itself. A caller that sets its own user-agent keeps it,
;; because a plist answers with the first pair it meets. A header set
;; written as pairs, (("X-Trace-Id" "7")), is left exactly as it is.
(define (http--headers opts)
  (let ((given (plist-get opts 'headers)))
    (cond ((not (pair? given)) (list 'user-agent http-user-agent))
          ((symbol? (car given)) (append given (list 'user-agent http-user-agent)))
          (else given))))

;; Every request leaves through here, so the defaults, the key references
;; and the seconds-to-milliseconds live in one place. The caller's own
;; pairs come first: first pair wins, in Scheme and in Elixir both.
(define (http--send url opts k)
  (let ((full (append (list 'headers (key-resolve-plist (http--headers opts)))
                      (http--opts opts)
                      (list 'timeout (* 1000 http-timeout)
                            'max-bytes http-max-bytes))))
    (if k (http-request url full k) (http-request url full))))

(define (http--with-method method opts)
  (cons 'method (cons method (http--opts opts))))

;; A plist body is JSON, because that is what an API asks for. A string
;; body is the bytes, and the caller says what they are with a
;; content-type. Anything else sends no body at all.
(define (http--with-body method body opts)
  (let ((o (http--opts opts)))
    (http--with-method method
      (cond ((string? body) (cons 'body (cons body o)))
            ((pair? body) (cons 'json (cons body o)))
            (else o)))))

(define (http-get url &optional opts k)
  (http--send url (http--with-method "GET" opts) k))

(define (http-head url &optional opts k)
  (http--send url (http--with-method "HEAD" opts) k))

(define (http-delete url &optional opts k)
  (http--send url (http--with-method "DELETE" opts) k))

(define (http-post url &optional body opts k)
  (http--send url (http--with-body "POST" body opts) k))

(define (http-put url &optional body opts k)
  (http--send url (http--with-body "PUT" body opts) k))

(define (http-patch url &optional body opts k)
  (http--send url (http--with-body "PATCH" body opts) k))

;;; --- the short forms ------------------------------------------------------------

;; The text of a page, or #f. This is the whole job of a curl inside a
;; shell-command->string, which is how five other packages still do it.
(define (http-text url &optional opts k)
  (if k
      (http-get url opts (lambda (reply) (k (and (http-ok? reply) (http-body reply)))))
      (let ((reply (http-get url opts)))
        (and (http-ok? reply) (http-body reply)))))

;; The parsed JSON of a GET, or #f. A 500 with a JSON error body answers
;; #f here on purpose: a caller who wants the difference reads the reply.
(define (http-get-json url &optional opts k)
  (if k
      (http-get url opts (lambda (reply) (k (and (http-ok? reply) (http-json reply)))))
      (let ((reply (http-get url opts)))
        (and (http-ok? reply) (http-json reply)))))

;; The parsed JSON of a POST, or #f.
(define (http-post-json url body &optional opts k)
  (if k
      (http-post url body opts (lambda (reply) (k (and (http-ok? reply) (http-json reply)))))
      (let ((reply (http-post url body opts)))
        (and (http-ok? reply) (http-json reply)))))

(effects! '(write external))

;; A file on disk from a URL, #t when it arrived. The whole body is in
;; memory first, bounded by http-max-bytes: this is for a page, a feed or
;; a release asset, not for a disk image.
(define (http-download! url path &optional opts)
  (let ((reply (http-get url opts)))
    (if (http-ok? reply)
        (begin (write-file! path (http-body reply)) #t)
        #f)))

;;; --- M-x http -------------------------------------------------------------------

(define *http-buffer* "*http*")

(define (http--report reply)
  (string-append
    "HTTP " (http--text (or (http-status reply) "no answer")) "\n"
    (let ((e (http-error reply))) (if e (string-append e "\n") ""))
    (let ((h (plist-get reply 'headers)))
      (if (pair? h) (string-append "\n" (http--headers-text h) "\n") ""))
    "\n" (http-body reply) "\n"))

(define (http--headers-text h)
  (if (or (null? h) (null? (cdr h)))
      ""
      (string-append (http--text (car h)) ": " (http--text (cadr h)) "\n"
                     (http--headers-text (cddr h)))))

;; The answer goes into a buffer, because a status line and a body do not
;; fit in the echo area. The window the command was run from keeps point
;; and keeps focus.
(define (http--show! reply)
  (unless (buffer-exists? *http-buffer*) (buffer-create *http-buffer*))
  (buffer-delete-range! *http-buffer* 0 (buffer-size *http-buffer*))
  (buffer-insert! *http-buffer* 0 (http--report reply))
  (display-buffer-other-window! *http-buffer*))

(define-command "http" "Fetch a URL and show the answer in a buffer"
  (lambda ()
    (read-string "URL: "
      (lambda (url)
        (let ((u (string-trim url)))
          (unless (equal? u "")
            (message (string-append "GET " u))
            (http-get u '() (lambda (reply) (http--show! reply)))))))))

;;; --- the public surface ---------------------------------------------------------

(category! 'web)
(domain! 'web)
(effects! '(read external))

(public! 'http-get
  "(http-get URL [OPTS] [K]) — GET URL and answer (ok BOOL status N headers PLIST body STRING [json VALUE] [error TEXT]); with K the request runs off the lane and K gets the answer")
(public! 'http-head
  "(http-head URL [OPTS] [K]) — the headers and status of URL, with no body")
(public! 'http-text
  "(http-text URL [OPTS] [K]) — the body of URL as a string, or #f when the request failed")
(public! 'http-get-json
  "(http-get-json URL [OPTS] [K]) — the parsed JSON of a GET, or #f")
(public! 'http-ok?
  "(http-ok? REPLY) — #t when the status was 2xx")
(public! 'http-status
  "(http-status REPLY) — the HTTP status number, or #f when nothing answered")
(public! 'http-body
  "(http-body REPLY) — the response body as a string, always the bytes that arrived")
(public! 'http-json
  "(http-json REPLY) — the parsed JSON body, or #f when the body was not JSON")
(public! 'http-header
  "(http-header REPLY NAME) — one response header's value, by any capitalisation, or #f")
(public! 'http-error
  "(http-error REPLY) — why the request never reached a server, or #f")
(public! 'http-message
  "(http-message REPLY) — one readable line for a failure, or #f when the request succeeded")

(effects! '(write external))

(public! 'http-post
  "(http-post URL BODY [OPTS] [K]) — POST BODY to URL; a plist BODY is sent as JSON, a string BODY as its bytes")
(public! 'http-put
  "(http-put URL BODY [OPTS] [K]) — PUT BODY to URL")
(public! 'http-patch
  "(http-patch URL BODY [OPTS] [K]) — PATCH URL with BODY")
(public! 'http-delete
  "(http-delete URL [OPTS] [K]) — DELETE URL")
(public! 'http-post-json
  "(http-post-json URL BODY [OPTS] [K]) — the parsed JSON answer to a POST, or #f")
(public! 'http-download!
  "(http-download! URL PATH [OPTS]) — write the body of URL to PATH; #t when it arrived")
(public! 'http-request
  "(http-request URL [OPTS] [CALLBACK]) — the one primitive under all of these; OPTS is a plist of method, headers, params, body, json, form, timeout, connect-timeout, redirect and max-bytes")
(public! 'http
  "M-x http — fetch a URL and show the status, the headers and the body in a buffer")

(defrecipe! "fetch a URL"
  "(http-text {{url}})"
  (list (list 'url "URL: ")))

(defrecipe! "call a JSON API"
  "(http-get-json {{url}} '(headers (authorization (\"Bearer \" \"@TOKEN\"))))"
  (list (list 'url "URL: ")))
