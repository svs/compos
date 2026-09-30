;;; draw.scm --- architecture on a canvas: one draw surface, many backends.
;;;
;;; Working through a system's architecture is drawing it, so compos gives
;;; every agent one `draw` tool on its own MCP server (mcp__compos__draw).
;;; The tool names an action; this file routes it to a backend, and the
;;; backend owns the wire. tldraw Desktop is the default backend: it runs a
;;; local HTTP server that lists canvases, reads shapes, runs JavaScript
;;; against a live editor and takes screenshots.
;;;
;;; (define-draw-backend! 'name OPS) registers a backend. OPS is a plist of
;;; action symbols to handlers; each handler takes the tool's args plist and
;;; answers text. 'available? answers #t when the backend can take a call.
;;; A call picks its backend by the 'backend arg, else a "NAME:ID" doc id,
;;; else `draw-backend`.

(defgroup 'draw "Drawing canvases for system architecture.")

(defcustom 'draw-backend 'tldraw
  "The canvas backend a draw call goes to when it names none." 'group 'draw)

(defcustom 'draw-tldraw-server-file
  (string-append (getenv "HOME") "/Library/Application Support/tldraw/server.json")
  "Where tldraw Desktop writes its port and per-launch token." 'group 'draw)

;;; --- the backend registry -------------------------------------------------

(define *draw-backends* '())

(define (define-draw-backend! name ops)
  (set! *draw-backends* (alist-put *draw-backends* name ops))
  name)

(define (draw-backends) (map car *draw-backends*))

(define (draw--ops name)
  (let ((e (assoc name *draw-backends*))) (and e (cadr e))))

;; "tldraw:abc" -> (tldraw "abc"); a bare id keeps no backend
(define (draw--split-doc doc)
  (let ((i (and (string? doc) (string-index doc ":"))))
    (if (and i (draw--ops (string->symbol (substring doc 0 i))))
        (list (string->symbol (substring doc 0 i)) (substring doc (+ i 1) (string-length doc)))
        (list #f doc))))

(define (draw--backend-of args)
  (let ((named (plist-get args 'backend))
        (from-doc (car (draw--split-doc (plist-get args 'doc)))))
    (cond ((and (string? named) (not (equal? named ""))) (string->symbol named))
          (from-doc from-doc)
          (else draw-backend))))

;; the args a backend sees: its own doc id, without the routing prefix
(define (draw--local-args args)
  (let ((doc (plist-get args 'doc)))
    (if (string? doc)
        (plist-put args 'doc (cadr (draw--split-doc doc)))
        args)))

(define (draw-call action args)
  (let* ((name (draw--backend-of args))
         (ops (draw--ops name))
         (act (if (symbol? action) action (string->symbol action))))
    (cond
      ((not ops) (string-append "no draw backend named " (symbol->string name)))
      ((not (plist-get ops act))
       (string-append (symbol->string name) " cannot " (symbol->string act)))
      ((and (not (equal? act 'status)) (plist-get ops 'available?)
            (not ((plist-get ops 'available?))))
       (string-append (symbol->string name) " is not running"))
      (else ((plist-get ops act) (draw--local-args args))))))

;;; --- tldraw Desktop -------------------------------------------------------
;;; server.json holds the port and a token that changes every launch, so
;;; every call reads it again. A clean quit removes the file.

(define (draw-tldraw--server)
  (let ((text (and (file-exists? draw-tldraw-server-file)
                   (read-file draw-tldraw-server-file))))
    (and text (json-parse text))))

(define (draw-tldraw--url s path)
  (string-append "http://localhost:" (number->string (plist-get s 'port)) path))

(define (draw-tldraw--post path code)
  (let ((s (draw-tldraw--server)))
    (if (not s)
        "tldraw Desktop is not running"
        (let ((reply (http-post (draw-tldraw--url s path) code
                       (list 'headers (list 'authorization (string-append "Bearer " (plist-get s 'token))
                                            'content-type "text/plain")
                             'timeout 30000))))
          (or (http-message reply) (http-body reply))))))

(define (draw-tldraw--with-doc args k)
  (let ((doc (plist-get args 'doc)))
    (if (and (string? doc) (not (equal? doc "")))
        (k (json-encode doc))
        "name a doc: take its id from the docs action")))

(define-draw-backend! 'tldraw
  (list
    'available?
    (lambda ()
      (let ((s (draw-tldraw--server)))
        (and s (http-ok? (http-get (draw-tldraw--url s "/") '(timeout 2000))))))
    'status
    (lambda (args)
      (if (draw-tldraw--server) "tldraw Desktop is running" "tldraw Desktop is not running"))
    'docs
    (lambda (args) (draw-tldraw--post "/api/search" "return await api.getDocs()"))
    'shapes
    (lambda (args)
      (draw-tldraw--with-doc args
        (lambda (doc)
          (draw-tldraw--post "/api/search"
            (string-append "const p = await api.getShapes(" doc "); "
                           "return p.shapes.map(s => ({id: s.id, type: s.type, x: s.x, y: s.y, props: s.props, meta: s.meta}))")))))
    'bindings
    (lambda (args)
      (draw-tldraw--with-doc args
        (lambda (doc)
          (draw-tldraw--post "/api/search" (string-append "return await api.getBindings(" doc ")")))))
    'exec
    (lambda (args)
      (draw-tldraw--with-doc args
        (lambda (doc)
          (draw-tldraw--post (string-append "/api/doc/" (plist-get args 'doc) "/exec")
                             (or (plist-get args 'code) "")))))
    'search
    (lambda (args) (draw-tldraw--post "/api/search" (or (plist-get args 'code) "")))
    'screenshot
    (lambda (args)
      (draw-tldraw--with-doc args
        (lambda (doc)
          (draw-tldraw--post "/api/search"
            (string-append "return await api.getScreenshot(" doc
                           ", {size: " (json-encode (or (plist-get args 'size) "medium")) "})")))))))

;;; --- the MCP surface ------------------------------------------------------
;;; One tool on the compos server, so every agent that holds compos can draw.

(define-tool! 'draw
  (string-append
    "Draw and read system-architecture canvases. "
    "action: status, docs (list open canvases), shapes (a doc's shapes), bindings (its arrows' connections), "
    "exec (run JavaScript with a live `editor` on one doc), search (run JavaScript with the backend's `api`), "
    "screenshot (a doc's image; answers a file path). "
    "doc is a canvas id from docs, optionally prefixed with its backend as backend:id. "
    "backend picks the canvas app; it defaults to the user's draw-backend (tldraw Desktop).")
  '((action "string" "status, docs, shapes, bindings, exec, search or screenshot")
    (doc "string" "the canvas id" optional)
    (code "string" "JavaScript for exec or search" optional)
    (size "string" "screenshot size: small, medium, large or full" optional)
    (backend "string" "the backend to use instead of the default" optional))
  (lambda (args) (draw-call (or (plist-get args 'action) "status") args))
  '(write external))

(domain! 'draw)
(effects! '(write))
(public! 'define-draw-backend! "(define-draw-backend! 'name OPS) — register a canvas backend; OPS maps actions to handlers")
(effects! '(write external))
(public! 'draw-call "(draw-call ACTION ARGS) — run one draw action on the backend ARGS names, or the default")
(effects! '(read))
(public! 'draw-backends "(draw-backends) — the registered canvas backends")
