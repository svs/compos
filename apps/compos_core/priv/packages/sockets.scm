;;; sockets.scm --- one buffer for every socket the daemon holds.
;;;
;;; M-x sockets opens *sockets*: the listen sockets (rpc, http, app), the
;;; browser bridge, the MCP and LSP connections, the agent threads, the
;;; process buffers, and the file watchers. One row per socket.
;;;
;;;   r     restart the socket on this line
;;;   k     stop it
;;;   RET   visit it: the buffer behind it, or its detail
;;;   g / q refresh · bury
;;;
;;; The verbs delegate: each subsystem keeps its own restart semantics
;;; (mcp-hub-restart!, lsp-start!, agent-reconnect!, process-restart!,
;;; listener-restart!). This buffer only names the rows and routes the keys.

(domain! 'system)
(effects! '(destroy execute))

(define *sockets-buffer* "*sockets*")

;; the last scan, an alist of (ID . PLIST) — cells and verbs read this so
;; one g press sees one consistent snapshot
(define *sockets-rows* '())

(defface! 'sock-up 'fg "#2e6b45" 'weight "600")
(defface! 'sock-error 'fg "#a83a2b" 'weight "600")
(defface! 'sock-off 'fg "#8a857a")
(defface! 'sock-kind 'fg "#7a5a1a")
(defface! 'sock-name 'fg "#26356b" 'weight "600")

;;; --- what a row knows ---------------------------------------------------------

;; the id is "KIND:NAME" — the kind never contains a colon, so the first
;; colon splits it even when the name is a path. EXTRA is a plist tail for
;; row data one verb needs (the LSP restart wants name and root apart).
(define (sockets-row kind name status detail extra)
  (cons (string-append kind ":" name)
        (append (list 'kind kind 'name name 'status status 'detail detail)
                extra)))

(define (sockets-agent-status slug)
  (let ((info (agent-info slug)))
    (if (not info)
        "up"
        (let ((st (plist-get info 'status)))
          (if (symbol? st) (symbol->string st) st)))))

(define (sockets-scan!)
  (set! *sockets-rows*
    (append
      (map (lambda (l) (sockets-row "listener" (car l) (cadr l) (caddr l) '()))
           (socket-listeners))
      (list (sockets-row "browser" "chrome"
                         (if (browser-connected?) "connected" "down")
                         "extension websocket" '()))
      (map (lambda (c) (sockets-row "mcp" (car c) (cadr c) (list-ref c 3) '()))
           (mcp-connections))
      (map (lambda (c) (sockets-row "lsp" (car c) (cadr c) (list-ref c 3)
                                    (list 'lsp-name (caddr c) 'root (list-ref c 3))))
           (lsp-connections))
      (map (lambda (slug)
             (sockets-row "agent" slug (sockets-agent-status slug) "" '()))
           (agent-list))
      (map (lambda (p) (sockets-row "proc" (car p) "up" (cadr p) '()))
           (process-list))
      (map (lambda (path) (sockets-row "watch" path "up" "" '()))
           (watched-paths)))))

(define (sockets-plist id)
  (let ((e (assoc id *sockets-rows*)))
    (if e (cdr e) #f)))

;;; --- the list -----------------------------------------------------------------

(define (sockets-glyph status)
  (cond ((member status '("up" "ready" "connected")) "●")
        ((equal? status "error") "✖")
        ((equal? status "connecting") "◐")
        (else "○")))

(define (sockets-status-face status)
  (cond ((member status '("up" "ready" "connected")) "sock-up")
        ((equal? status "error") "sock-error")
        (else "sock-off")))

(define (sockets-ids buf)
  (sockets-scan!)
  (map car *sockets-rows*))

(define (sockets-cells buf id)
  (let ((row (sockets-plist id)))
    (if (not row)
        (list (list "○" "sock-off") (list "?" "sock-kind")
              (list id "sock-name") (list "" "dim") (list "" "faint"))
        (let ((status (plist-get row 'status)))
          (list (list (sockets-glyph status) (sockets-status-face status))
                (list (plist-get row 'kind) "sock-kind")
                (list (plist-get row 'name) "sock-name")
                (list status (sockets-status-face status))
                (list (plist-get row 'detail) "faint"))))))

(define (sockets-refresh!) (list-refresh! *sockets-buffer*))

(define (sockets-on-current fn)
  (let ((id (list-current *sockets-buffer*)))
    (if (not id)
        (message "no socket on this line")
        (let ((row (sockets-plist id)))
          (if row (fn row) (message "stale row — g refreshes"))))))

;;; --- restart, stop, visit -----------------------------------------------------

(define (sockets-lsp-restart! row)
  (let* ((id (plist-get row 'name))
         (name (plist-get row 'lsp-name))
         (root (plist-get row 'root))
         (e (assoc name *lsp-registry*)))
    (lsp-stop! id)
    (if e
        (lsp-start! name root (cadr e))
        (message (string-append name " is not in the LSP registry")))))

;; fresh provider session on the same connector and model; the transcript
;; stays (agent.scm owns those semantics)
(define (sockets-agent-restart! slug)
  (let ((buf (agent-buf slug)))
    (agent-reconnect! slug
      (buffer-local buf 'agent-connector)
      (or (buffer-local buf 'agent-model) ""))))

(define (sockets-restart! row)
  (let ((kind (plist-get row 'kind))
        (name (plist-get row 'name)))
    (cond ((equal? kind "listener")
           (listener-restart! name)
           (message (string-append name " restarted")))
          ((equal? kind "mcp") (mcp-hub-restart! name))
          ((equal? kind "lsp") (sockets-lsp-restart! row))
          ((equal? kind "agent") (sockets-agent-restart! name))
          ((equal? kind "proc")
           (if (process-restart! name)
               (message (string-append name " restarted"))
               (message (string-append name " did not restart"))))
          ((equal? kind "browser")
           (message "the extension reconnects itself — no daemon-side restart"))
          (else (message (string-append kind " does not restart"))))
    (sockets-refresh!)))

(define (sockets-stop! row)
  (let ((kind (plist-get row 'kind))
        (name (plist-get row 'name)))
    (cond ((equal? kind "mcp") (mcp-disconnect! name))
          ((equal? kind "lsp") (lsp-stop! name))
          ((equal? kind "agent") (agent-kill! name))
          ((equal? kind "proc") (process-kill! name))
          ((equal? kind "watch") (unwatch-path! name))
          (else (message (string-append kind " does not stop — r restarts it"))))
    (sockets-refresh!)))

(define (sockets-visit! row)
  (let ((kind (plist-get row 'kind))
        (name (plist-get row 'name)))
    (cond ((equal? kind "mcp") (mcp-hub-show-detail name))
          ((equal? kind "proc") (display-buffer name))
          ((equal? kind "agent") (display-buffer (agent-buf name)))
          (else
            (let ((detail (plist-get row 'detail)))
              (message (string-append name " — " (plist-get row 'status)
                                      (if (equal? detail "")
                                          ""
                                          (string-append " · " detail)))))))))

(define-command "sockets-restart" "Restart the socket on this line"
  (lambda () (sockets-on-current sockets-restart!)))

(define-command "sockets-stop" "Stop the socket on this line"
  (lambda () (sockets-on-current sockets-stop!)))

(define-command "sockets-visit" "Visit the socket on this line"
  (lambda () (sockets-on-current sockets-visit!)))

(define-command "sockets-refresh" "Redraw the socket list"
  (lambda () (sockets-refresh!)))

;;; --- the hub -------------------------------------------------------------------

(mode-icon! "sockets-mode" "")

(define-list-mode! "sockets-mode"
  (list
    'doc (string-append
           "Every socket the daemon holds: listen sockets, the browser bridge, "
           "MCP and LSP connections, agent threads, process buffers, and file "
           "watchers. `r` restarts the row, `k` stops it, `RET` visits it.")
    'buffer *sockets-buffer*
    'rows sockets-ids
    'columns (lambda (buf)
               (list (list "" 1) (list "kind" 8) (list "name" 30)
                     (list "status" 12) (list "detail" #f)))
    'cells sockets-cells
    'title (lambda (buf) "Sockets")
    'meta (lambda (buf)
            (string-append (number->string (length (list-entries buf))) " sockets"))
    'total (lambda (buf) (length (list-source-entries buf)))
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "visit") ("r" "restart") ("k" "stop")
                ("/" "filter") ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "sockets-visit") ("r" "sockets-restart")
            ("k" "sockets-stop") ("g" "sockets-refresh")
            ("q" "quit-window"))))

(define-command "sockets"
  "List every socket the daemon holds. To open a client connection to another program, use endpoint-register!"
  (lambda () (list-mode-show! "sockets-mode")))

(define-key "agent-map" "s" "sockets")

(category! 'system)
(public! 'sockets-refresh! "(sockets-refresh!) — redraw *sockets* if it exists")
