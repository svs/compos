;;; graphql.scm --- one GraphQL client for the whole editor, userland Scheme.
;;;
;;; A GraphQL API is one URL and one POST. Everything else is the work:
;;; who you are to that server, what the server will answer for, and what
;;; came back. This file holds those three, and no Elixir knows about any
;;; of it.
;;;
;;; Register an endpoint once, by name:
;;;
;;;   (graphql-register! 'ats "https://ats.example.com/gql"
;;;     'headers (list 'Authorization (list "Bearer " "@ATS_ASH_TOKEN")))
;;;
;;; "@ATS_ASH_TOKEN" is a reference, not a key. keys.scm resolves it at the
;;; moment the request leaves, so the token is not in this file and not in
;;; the registry. It is also not in the process list: curl reads the URL,
;;; the headers and the body from a config file that lives for one request
;;; and is then deleted. A header on a command line is readable by every
;;; process on the machine, and the header is where the token is.
;;;
;;; Then ask:
;;;
;;;   (graphql 'ats "query { me { name } }")
;;;
;;; A server answers only for the schema it has, so find the schema the way
;;; you find the editor — by words, not by regex:
;;;
;;;   (graphql-apropos 'ats "candidate stage")
;;;   (graphql-describe 'ats "Candidate")
;;;
;;; There is no graphql tool for the model, on purpose. The model has
;;; eval-scheme, and these functions are Scheme.

(defgroup 'graphql "GraphQL: endpoints, and the requests the editor makes to them.")

(defcustom 'graphql-curl-program "curl"
  "The curl executable the GraphQL client shells out to." 'group 'graphql)

(defcustom 'graphql-timeout 30
  "Seconds to wait for one GraphQL response." 'group 'graphql)

(defcustom 'graphql-apropos-limit 60
  "The most schema lines one graphql-apropos prints." 'group 'graphql)

;;; --- small helpers ------------------------------------------------------------

(define (graphql--text v)
  (if (symbol? v) (symbol->string v) v))

;; JSON null parses to #f, and a GraphQL answer is full of nulls: an absent
;; object, a type with no fields, a schema with no mutation. plist-get wants
;; a list and stops the interpreter when it gets #f, so nothing here reads a
;; plist any other way.
(define (graphql--get pl key)
  (if (pair? pl) (plist-get pl key) #f))

(define (graphql--replace s from to)
  (string-join (string-split s from) to))

(define (graphql--take xs n)
  (if (or (null? xs) (< n 1))
      '()
      (cons (car xs) (graphql--take (cdr xs) (- n 1)))))

(define (graphql--first-line s)
  (if (string? s) (string-trim (car (string-split s "\n"))) ""))

;; " — description", or nothing at all. A schema description can run for
;; paragraphs; a catalog line takes the first line of it.
(define (graphql--dash d)
  (let ((first (graphql--first-line d)))
    (if (equal? first "") "" (string-append "  — " first))))

;;; --- the registry -------------------------------------------------------------
;;; An endpoint is a name, a URL and headers. The headers hold references,
;;; not secrets, so the registry stays safe to print.

(define *graphql-endpoints* '())        ; ((name url headers doc) ...)

(define (graphql-register! name url &rest opts)
  (set! *graphql-endpoints*
    (cons (list name url
                (or (graphql--get opts 'headers) '())
                (or (graphql--get opts 'doc) ""))
          (remove (lambda (e) (equal? (car e) name)) *graphql-endpoints*)))
  name)

(define (graphql-forget! name)
  (set! *graphql-endpoints*
    (remove (lambda (e) (equal? (car e) name)) *graphql-endpoints*))
  (graphql-schema-forget! name)
  name)

(define (graphql--endpoint name) (assoc name *graphql-endpoints*))

(define (graphql-endpoints)
  (if (null? *graphql-endpoints*)
      "no GraphQL endpoints — register one with (graphql-register! 'name URL)"
      (fold (lambda (acc e)
              (string-append acc (graphql--text (car e)) "  " (cadr e)
                             (graphql--dash (nth 3 e)) "\n"))
            "" (reverse *graphql-endpoints*))))

;;; --- the wire -----------------------------------------------------------------

(define *graphql--seq* 0)

;; One request writes two files and deletes both. The name carries the clock
;; and a counter, so two requests in the same second do not collide.
(define (graphql--tmp-path suffix)
  (set! *graphql--seq* (+ *graphql--seq* 1))
  (let ((dir (string-append (aimax-home) "/tmp")))
    (make-directory! dir)
    (string-append dir "/graphql-" (number->string (current-time))
                   "-" (number->string *graphql--seq*) suffix)))

;; curl reads a quoted config value with backslash escapes. The backslash
;; goes first: escape it after the quote and you escape your own escapes.
(define (graphql--escape s)
  (graphql--replace (graphql--replace (graphql--text s) "\\" "\\\\") "\"" "\\\""))

(define (graphql--shell-quote s)
  (string-append "'" (graphql--replace s "'" "'\\''") "'"))

(define (graphql--header-lines headers)
  (if (or (null? headers) (null? (cdr headers)))
      ""
      (string-append "header = \"" (graphql--escape (car headers)) ": "
                     (graphql--escape (cadr headers)) "\"\n"
                     (graphql--header-lines (cddr headers)))))

;; write-out puts the HTTP status on the last line, because a server that
;; refuses the request often answers in HTML, and "401" reads better than
;; the first 2000 characters of a login page.
(define (graphql--config url headers body-path)
  (string-append
    "url = \"" (graphql--escape url) "\"\n"
    "request = \"POST\"\n"
    "header = \"Content-Type: application/json\"\n"
    (graphql--header-lines (key-resolve-plist headers))
    "data-binary = \"@" (graphql--escape body-path) "\"\n"
    "max-time = " (number->string graphql-timeout) "\n"
    "silent\n"
    "show-error\n"
    "write-out = \"\\n%{http_code}\"\n"))

(define (graphql--curl url headers body)
  (let ((body-path (graphql--tmp-path ".json"))
        (conf-path (graphql--tmp-path ".conf")))
    (write-file! body-path body)
    (write-file! conf-path (graphql--config url headers body-path))
    (let ((out (shell-command->string
                 (string-append graphql-curl-program " --config "
                                (graphql--shell-quote conf-path)))))
      (delete-file! body-path)
      (delete-file! conf-path)
      out)))

;; (STATUS BODY). curl itself failing prints no status line at all, so a
;; last line that is not a number means the whole output is the complaint.
(define (graphql--split-status out)
  (let* ((lines (string-split out "\n"))
         (last (car (reverse lines)))
         (status (string->number last)))
    (if (number? status)
        (list status (string-join (reverse (cdr (reverse lines))) "\n"))
        (list 0 out))))

;; An empty plist encodes as [], and a server rejects [] where it wants an
;; object. A key with nothing to say is left out instead.
(define (graphql--body query variables operation)
  (json-encode
    (append (list 'query query)
            (if (null? variables) '() (list 'variables variables))
            (if operation (list 'operationName (graphql--text operation)) '()))))

(define (graphql--fail text)
  (list 'errors (list (list 'message text))))

(define (graphql--has? pl key)
  (cond ((null? pl) #f)
        ((null? (cdr pl)) #f)
        ((equal? (car pl) key) #t)
        (else (graphql--has? (cddr pl) key))))

;;; --- the request --------------------------------------------------------------

;; The whole reply, parsed: (data ... errors ...). Every failure — no such
;; endpoint, no network, HTML from a proxy — comes back in the same shape,
;; so one caller reads one thing. This never throws.
(define (graphql-post name query &optional variables operation)
  (let ((e (graphql--endpoint name)))
    (if (not e)
        (graphql--fail (string-append "no such GraphQL endpoint: " (graphql--text name)))
        (let* ((res (graphql--split-status
                      (graphql--curl (cadr e) (nth 2 e)
                                     (graphql--body query (or variables '()) operation))))
               (status (car res))
               (text (cadr res))
               (reply (json-parse text)))
          (cond
            ;; a GraphQL answer says data or errors, whatever the status
            ((and (pair? reply)
                  (or (graphql--has? reply 'data) (graphql--has? reply 'errors)))
             reply)
            ((= status 0)
             ;; curl names itself in its own complaints, so this does not
             (graphql--fail (string-append "the request failed: " (string-trim text))))
            (else
              (graphql--fail (string-append "HTTP " (number->string status) ": "
                                            (graphql--first-line text)))))))))

(define (graphql--path->string p)
  (string-join (map (lambda (x) (if (number? x) (number->string x) (graphql--text x))) p) "."))

;; Readable text for every error in REPLY, or #f when there are none.
(define (graphql-errors reply)
  (let ((es (graphql--get reply 'errors)))
    (if (or (not es) (null? es))
        #f
        (string-trim
          (fold (lambda (acc e)
                  (let ((path (graphql--get e 'path)))
                    (string-append acc (or (graphql--get e 'message) "error")
                                   (if (pair? path)
                                       (string-append "  (at " (graphql--path->string path) ")")
                                       "")
                                   "\n")))
                "" es)))))

(define *graphql-last-error* #f)

(define (graphql-last-error) *graphql-last-error*)

;; The data of one query. GraphQL may answer with data AND errors, so the
;; data comes back either way and the errors are always recorded: the echo
;; area gets the first line, (graphql-last-error) keeps them all. #f means
;; the server sent no data at all.
(define (graphql name query &optional variables)
  (let* ((reply (graphql-post name query variables))
         (err (graphql-errors reply)))
    (set! *graphql-last-error* err)
    (when err (message (string-append "graphql: " (graphql--first-line err))))
    (graphql--get reply 'data)))

;;; --- the schema ---------------------------------------------------------------
;;; Introspection is one query and the answer is large, so it is fetched
;;; once per endpoint and kept. A server that changes its schema needs a
;;; graphql-schema-forget!.

;; A type reference nests: [Country!]! is NON_NULL of LIST of NON_NULL of
;; Country. Four levels reach the name in every shape a schema uses.
(define graphql--type-fragment
  (string-append "fragment T on __Type { kind name"
                 " ofType { kind name ofType { kind name ofType { kind name } } } }"))

(define graphql--roots-part
  " query { __schema { queryType { name } mutationType { name }")

;; Full introspection is a deep query, and a gateway that caps query depth
;; refuses it. So the client asks for less, in this order, and keeps the
;; first answer. (graphql-schema-detail 'NAME) says which one answered.
(define graphql--introspections
  (list
    (list 'full
      (string-append graphql--type-fragment graphql--roots-part
        " types { name kind description"
        " fields(includeDeprecated: true) { name description type { ...T }"
        " args { name type { ...T } } }"
        " inputFields { name description type { ...T } } } } }"))
    (list 'no-args
      (string-append graphql--type-fragment graphql--roots-part
        " types { name kind description"
        " fields(includeDeprecated: true) { name description type { ...T } }"
        " inputFields { name description type { ...T } } } } }"))
    (list 'shallow
      (string-append graphql--roots-part
        " types { name kind description"
        " fields(includeDeprecated: true) { name description type { kind name } } } } }"))
    (list 'names
      (string-append graphql--roots-part " types { name kind description } } }"))))

(define *graphql-schemas* '())          ; ((name types schema detail) ...)

(define (graphql-schema-forget! name)
  (set! *graphql-schemas*
    (remove (lambda (s) (equal? (car s) name)) *graphql-schemas*))
  name)

;; The ladder, quietly: only the last word goes to the echo area, because
;; three refusals on the way to an answer are not three problems.
(define (graphql--introspect name)
  (let loop ((qs graphql--introspections) (err #f))
    (if (null? qs)
        (begin (set! *graphql-last-error* err)
               (message (string-append "graphql: no schema from " (graphql--text name)))
               #f)
        (let* ((reply (graphql-post name (cadr (car qs))))
               (e (graphql-errors reply))
               (schema (graphql--get (graphql--get reply 'data) '__schema)))
          (if (and (not e) (pair? schema))
              (list (car (car qs)) schema)
              (loop (cdr qs) e))))))

;; Every type the endpoint declares, or #f with the reason in
;; (graphql-last-error).
(define (graphql-schema name)
  (let ((hit (assoc name *graphql-schemas*)))
    (if hit
        (cadr hit)
        (let ((got (graphql--introspect name)))
          (if (not got)
              #f
              (let* ((schema (cadr got))
                     (types (or (graphql--get schema 'types) '())))
                (set! *graphql-schemas*
                  (cons (list name types schema (car got)) *graphql-schemas*))
                types))))))

;; How much of the schema arrived: full, no-args, shallow or names.
(define (graphql-schema-detail name)
  (let ((hit (assoc name *graphql-schemas*)))
    (if hit (nth 3 hit) #f)))

(define (graphql--partial-note name)
  (let ((detail (graphql-schema-detail name)))
    (cond ((or (not detail) (equal? detail 'full)) "")
          ((equal? detail 'no-args)
           "(the server capped query depth: field arguments are missing)\n")
          ((equal? detail 'shallow)
           "(the server capped query depth: list and non-null marks are missing)\n")
          (else "(the server capped query depth: fields are missing, type names only)\n"))))

;; "[Candidate!]!" — NON_NULL and LIST are wrappers with no name of their
;; own, so the name is at the bottom of ofType.
;; A wrapper with no ofType is a shallow introspection, not a type called
;; "?!" — the mark goes away with the level that would have carried it.
(define (graphql--type-name t)
  (cond ((not (pair? t)) "?")
        ((and (equal? (graphql--get t 'kind) "NON_NULL") (pair? (graphql--get t 'ofType)))
         (string-append (graphql--type-name (graphql--get t 'ofType)) "!"))
        ((and (equal? (graphql--get t 'kind) "LIST") (pair? (graphql--get t 'ofType)))
         (string-append "[" (graphql--type-name (graphql--get t 'ofType)) "]"))
        (else (or (graphql--get t 'name) "?"))))

(define (graphql--args-string f)
  (let ((args (graphql--get f 'args)))
    (if (or (not (pair? args)) (null? args))
        ""
        (string-append "("
          (string-join
            (map (lambda (a)
                   (string-append (or (graphql--get a 'name) "?") ": "
                                  (graphql--type-name (graphql--get a 'type))))
                 args)
            ", ")
          ")"))))

(define (graphql--type-line ty)
  (string-append (or (graphql--get ty 'name) "?")
                 "  (" (string-downcase (or (graphql--get ty 'kind) "?")) ")"
                 (graphql--dash (graphql--get ty 'description))))

(define (graphql--field-line ty f)
  (string-append (or (graphql--get ty 'name) "?") "." (or (graphql--get f 'name) "?")
                 (graphql--args-string f)
                 ": " (graphql--type-name (graphql--get f 'type))
                 (graphql--dash (graphql--get f 'description))))

;; Introspection describes itself as well: __Type, __Field and the rest.
;; Nobody searches for those, so they stay out of the lines.
(define (graphql--own-type? ty)
  (string-prefix? "__" (or (graphql--get ty 'name) "")))

(define (graphql--type-lines ty)
  (append (list (graphql--type-line ty))
          (map (lambda (f) (graphql--field-line ty f))
               (or (graphql--get ty 'fields) '()))
          (map (lambda (f) (graphql--field-line ty f))
               (or (graphql--get ty 'inputFields) '()))))

(define (graphql--schema-lines types)
  (fold (lambda (acc ty)
          (if (graphql--own-type? ty) acc (append acc (graphql--type-lines ty))))
        '() types))

;; every word, in any order, anywhere in the line — the same discipline as
;; the editor's own apropos, so one habit covers both
(define (graphql--matches? line words)
  (let ((hay (string-downcase line)))
    (fold (lambda (acc w) (and acc (string-contains? hay w))) #t words)))

(define (graphql--words query)
  (filter (lambda (w) (not (equal? w "")))
          (map string-downcase (string-split (string-trim query) " "))))

;; The types and fields of NAME's schema that hold every word of QUERY.
(define (graphql-apropos name query)
  (let ((types (graphql-schema name)))
    (if (not types)
        (or *graphql-last-error* "no schema")
        (let* ((hits (filter (lambda (l) (graphql--matches? l (graphql--words query)))
                             (graphql--schema-lines types)))
               (shown (graphql--take hits graphql-apropos-limit))
               (more (- (length hits) (length shown))))
          (if (null? hits)
              (string-append "nothing in " (graphql--text name)
                             "'s schema holds every word of \"" query "\"")
              (string-append
                (string-join shown "\n") "\n"
                ;; a silent cut reads like "that is all there is"
                (if (> more 0)
                    (string-append "... and " (number->string more)
                                   " more — narrow the words, or raise graphql-apropos-limit\n")
                    "")
                (graphql--partial-note name)))))))

(define (graphql--find-type types name)
  (let ((wanted (string-downcase (graphql--text name))))
    (let loop ((ts types))
      (cond ((null? ts) #f)
            ((equal? (string-downcase (or (graphql--get (car ts) 'name) "")) wanted) (car ts))
            (else (loop (cdr ts)))))))

;; One type in full: what it is, what it says, and every field it answers for.
(define (graphql-describe name type-name)
  (let ((types (graphql-schema name)))
    (if (not types)
        (or *graphql-last-error* "no schema")
        (let ((ty (graphql--find-type types type-name)))
          (if (not ty)
              (string-append "no type " (graphql--text type-name) " in "
                             (graphql--text name) "'s schema — try (graphql-apropos '"
                             (graphql--text name) " \"" (graphql--text type-name) "\")")
              (let ((fields (cdr (graphql--type-lines ty))))
                (string-append (graphql--type-line ty) "\n"
                               (if (null? fields)
                                   "(no fields — a scalar, an enum or a union)\n"
                                   (string-append (string-join fields "\n") "\n"))
                               (graphql--partial-note name))))))))

;; Where a query starts and where a mutation starts. Every schema names
;; these two, and they are the only entry points a caller has.
(define (graphql-roots name)
  (let ((types (graphql-schema name)))
    (if (not types)
        (or *graphql-last-error* "no schema")
        (let ((schema (nth 2 (assoc name *graphql-schemas*))))
          (string-append
            "query:    " (or (graphql--get (graphql--get schema 'queryType) 'name) "none") "\n"
            "mutation: " (or (graphql--get (graphql--get schema 'mutationType) 'name) "none") "\n")))))

;;; --- reading the answer -------------------------------------------------------
;;; JSON in, Scheme out: an object becomes a plist and an array becomes a
;;; list, which are the same shape. A plist has an even length and a symbol
;;; in every key position, and that is what tells them apart here. An array
;;; of symbols would fool it, and JSON has no symbols to send.

(define (graphql--object? v)
  (and (pair? v)
       (let loop ((xs v))
         (cond ((null? xs) #t)
               ((not (symbol? (car xs))) #f)
               ((null? (cdr xs)) #f)
               (else (loop (cddr xs)))))))

(define (graphql--composite? v)
  (and (pair? v) (not (null? v))))

(define (graphql--scalar v)
  (cond ((null? v) "[]")
        ((equal? v #f) "null")                  ; JSON null parses to #f
        ((equal? v #t) "true")
        ((string? v) v)
        ((number? v) (number->string v))
        (else "?")))

(define (graphql--pad n) (string-repeat " " n))

;; Text for one composite value. Every line carries INDENT, and the text
;; ends with a newline. A scalar never comes here.
(define (graphql--block v indent)
  (if (graphql--object? v)
      (graphql--object-block v indent)
      (graphql--array-block v indent)))

;; the first line without its indent, so a caller can put something else there
(define (graphql--inline text indent)
  (substring-bytes text indent (string-byte-length text)))

(define (graphql--object-block v indent)
  (let loop ((xs v) (out ""))
    (if (or (null? xs) (null? (cdr xs)))
        out
        (let ((key (graphql--text (car xs)))
              (val (cadr xs)))
          (loop (cddr xs)
                (string-append out (graphql--pad indent) key ":"
                               (if (graphql--composite? val)
                                   (string-append "\n" (graphql--block val (+ indent 2)))
                                   (string-append " " (graphql--scalar val) "\n"))))))))

(define (graphql--array-block v indent)
  (fold (lambda (out item)
          (string-append out (graphql--pad indent) "- "
                         (if (graphql--composite? item)
                             (graphql--inline (graphql--block item (+ indent 2)) (+ indent 2))
                             (string-append (graphql--scalar item) "\n"))))
        "" v))

;; Any parsed GraphQL value as text a person can read. Scalars included.
(define (graphql-print v)
  (if (graphql--composite? v)
      (graphql--block v 0)
      (string-append (graphql--scalar v) "\n")))

;;; --- the buffer ---------------------------------------------------------------

(define (graphql--buffer name)
  (string-append "*graphql: " (graphql--text name) "*"))

;; Run QUERY and show the answer beside this window. The query stays at the
;; top of the buffer, because an answer with no question is a puzzle.
(define (graphql-run name query &optional variables)
  (let* ((buf (graphql--buffer name))
         (reply (graphql-post name query variables))
         (err (graphql-errors reply))
         (data (graphql--get reply 'data)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf (string-append (string-trim query) "\n\n"))
    (when err (buffer-append! buf (string-append "errors:\n" err "\n\n")))
    (buffer-append! buf (if data (graphql-print data) "no data\n"))
    (display-buffer-other-window! buf)
    buf))

;; A command takes its domain and its effects from the state in force when
;; it is declared, so the two are set here rather than with the functions
;; below: a command that says what it does needs no backfill to guess.
(category! 'graphql)

(effects! '(write external))
(define-command "graphql-query" "Run a GraphQL query against a registered endpoint"
  (lambda ()
    (if (null? *graphql-endpoints*)
        (message "no GraphQL endpoints — register one with (graphql-register! 'name URL)")
        (minibuffer-read "Endpoint: "
          (map (lambda (e) (graphql--text (car e))) *graphql-endpoints*)
          (lambda (ep)
            (minibuffer-read "Query: " '()
              (lambda (q) (graphql-run (string->symbol ep) q))))))))

(effects! '(read))
(define-command "graphql-endpoints" "List the registered GraphQL endpoints"
  (lambda () (message (string-trim (graphql-endpoints)))))

;;; --- the catalog --------------------------------------------------------------

(effects! '(write))
(public! 'graphql-register!
  "(graphql-register! 'NAME URL ['headers PLIST] ['doc TEXT]) — name a GraphQL endpoint; a \"@VAR\" header value is a key reference, not a key")
(public! 'graphql-forget!
  "(graphql-forget! 'NAME) — drop an endpoint and its cached schema")
(public! 'graphql-schema-forget!
  "(graphql-schema-forget! 'NAME) — drop the cached schema; the next question re-introspects")

(effects! '(read))
(public! 'graphql-endpoints
  "(graphql-endpoints) — every registered endpoint with its URL, secrets never")
(public! 'graphql-last-error
  "(graphql-last-error) — the errors from the last graphql call, or #f")
(public! 'graphql-print
  "(graphql-print VALUE) — a parsed GraphQL value as indented text")

(effects! '(read external))
(public! 'graphql
  "(graphql 'NAME QUERY [VARIABLES]) — run one query and return its data; errors go to the echo area and (graphql-last-error)")
(public! 'graphql-post
  "(graphql-post 'NAME QUERY [VARIABLES] [OPERATION]) — the whole reply plist: data, errors, or both; never throws")
(public! 'graphql-errors
  "(graphql-errors REPLY) — readable text for every error in a reply, or #f")
(public! 'graphql-schema
  "(graphql-schema 'NAME) — every type the endpoint declares, introspected once and kept")
(public! 'graphql-schema-detail
  "(graphql-schema-detail 'NAME) — how much of the schema the server allowed: full, no-args, shallow or names")
(public! 'graphql-apropos
  "(graphql-apropos 'NAME QUERY) — search a schema by WORDS, not regex: the types and fields holding every word")
(public! 'graphql-describe
  "(graphql-describe 'NAME TYPE) — one type in full, with every field and its arguments")
(public! 'graphql-roots
  "(graphql-roots 'NAME) — the query type and the mutation type: where every request starts")

(effects! '(write external))
(public! 'graphql-run
  "(graphql-run 'NAME QUERY [VARIABLES]) — run a query and show the answer in *graphql: NAME*")

(effects! '(read external))
(defrecipe! "run a graphql query"
  "(graphql (string->symbol {{endpoint}}) {{query}})"
  (list (list 'endpoint "Endpoint: ") (list 'query "GraphQL query: ")))
(defrecipe! "search a graphql schema"
  "(graphql-apropos (string->symbol {{endpoint}}) {{query}})"
  (list (list 'endpoint "Endpoint: ") (list 'query "Schema search: ")))
(defrecipe! "see one graphql type"
  "(graphql-describe (string->symbol {{endpoint}}) {{type}})"
  (list (list 'endpoint "Endpoint: ") (list 'type "Type: ")))
(defrecipe! "see where graphql queries start"
  "(graphql-roots (string->symbol {{endpoint}}))"
  (list (list 'endpoint "Endpoint: ")))

(effects! '(write))
(defrecipe! "name a graphql endpoint"
  "(graphql-register! (string->symbol {{name}}) {{url}})"
  (list (list 'name "Endpoint name: ") (list 'url "GraphQL URL: ")))

(effects! '(write external))
(defrecipe! "show a graphql answer in a buffer"
  "(graphql-run (string->symbol {{endpoint}}) {{query}})"
  (list (list 'endpoint "Endpoint: ") (list 'query "GraphQL query: ")))
