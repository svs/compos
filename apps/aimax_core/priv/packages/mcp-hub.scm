;;; mcp-hub.scm --- the MCP server list, the way mcp.el has one.
;;;
;;; M-x mcp-hub opens *mcp-hub*: every server the registry knows, running or
;;; not, with what it is serving. mcp.scm holds the registry and decides
;;; which chat sees which servers; this file is the surface you drive it
;;; from — start, stop, restart, look at the tools, read the wire.
;;;
;;;   s / k / r     start · stop · restart the server on this line
;;;   S / K / R     all of them
;;;   RET / d       what this server serves: tools, resources, prompts
;;;   l             the JSON-RPC frames, both directions
;;;   g / q         refresh · bury
;;;
;;; The rows redraw themselves: a connection announces ready/stopped/error
;;; through mcp-on-change!, because a row that sits on "connecting" forever
;;; reads as a broken feature, and the editor has no timer to poll with.

(define *mcp-hub-buffer* "*mcp-hub*")

(set-face-attribute! 'mcp-ready 'fg "#2e6b45" 'weight "600")
(set-face-attribute! 'mcp-error 'fg "#a83a2b" 'weight "600")
(set-face-attribute! 'mcp-off 'fg "#8a857a")
(set-face-attribute! 'mcp-name 'fg "#26356b" 'weight "600")
(set-face-attribute! 'mcp-preset 'fg "#7a5a1a")
(set-face-attribute! 'mcp-heading 'fg "#26356b" 'weight "700")
(set-face-attribute! 'mcp-item 'fg "#7a5a1a" 'weight "600")
(set-face-attribute! 'mcp-dim 'fg "#8a857a")

;;; --- what a row knows ---------------------------------------------------------

;; declaration order: the registry prepends, and the editor's own proxy is
;; registered first, so reversing puts 'aimax at the top where it belongs
(define (mcp-hub-names)
  (map (lambda (e) (symbol->string (car e))) (reverse *mcp-registry*)))

(define (mcp-hub-spec name)
  (let ((e (assoc (string->symbol name) *mcp-registry*)))
    (if e (cadr e) '())))

(define (mcp-hub-live name)
  (let loop ((cs (mcp-connections)))
    (cond ((null? cs) #f)
          ((equal? (car (car cs)) name) (car cs))
          (else (loop (cdr cs))))))

;; the presets that carry this server — ours, not mcp.el's: which chats can
;; reach a server is the question the registry alone can't answer
(define (mcp-hub-presets name)
  (let ((sym (string->symbol name)))
    (reverse
      (fold (lambda (acc p)
              (if (member sym (preset-servers (car p)))
                  (cons (symbol->string (car p)) acc)
                  acc))
            '() *chat-presets*))))

;; live connection first; failing that, whatever the last one left behind
;; (a server that died mid-handshake still owes the user an explanation)
(define (mcp-hub-row name)
  (let ((live (mcp-hub-live name))
        (spec (mcp-hub-spec name)))
    (if live
        (list name (cadr live) (caddr live) (list-ref live 3)
              (list-ref live 4) (list-ref live 5))
        (let ((last (mcp-server-detail name)))
          (list name
                (if last (plist-get last 'status) "stopped")
                #f
                (if (plist-get spec 'command) "stdio" "http")
                #f #f)))))

(define (mcp-hub-status-face status)
  (cond ((equal? status "ready") "mcp-ready")
        ((equal? status "error") "mcp-error")
        (else "mcp-off")))

(define (mcp-hub-glyph status)
  (cond ((equal? status "ready") "●")
        ((equal? status "error") "✖")
        ((equal? status "connecting") "◐")
        (else "○")))

(define (mcp-hub-fit s n)
  (let ((s (or s "")))
    (string-pad-right (if (> (string-length s) n) (substring s 0 n) s) n)))

(define (mcp-hub-count n)
  (string-pad-right (if n (number->string n) "—") 6))

;;; --- the list -----------------------------------------------------------------

(define (mcp-hub-line row)
  (let ((status (cadr row)))
    (string-append
      (mcp-hub-glyph status) " "
      (mcp-hub-fit (car row) 16) " "
      (mcp-hub-fit (list-ref row 3) 5) " "
      (mcp-hub-fit status 10) " "
      (mcp-hub-count (caddr row))
      (mcp-hub-count (list-ref row 4))
      (mcp-hub-count (list-ref row 5))
      (string-join (mcp-hub-presets (car row)) " "))))

(define (mcp-hub-header)
  (string-append
    ";; mcp servers — s start · k stop · r restart · S/K/R all · "
    "RET tools · l log · g refresh\n"
    "  "
    (mcp-hub-fit "NAME" 16) " " (mcp-hub-fit "TYPE" 5) " "
    (mcp-hub-fit "STATUS" 10) " "
    (mcp-hub-fit "TOOLS" 6) (mcp-hub-fit "RES" 6)
    (mcp-hub-fit "PROM" 6) "PRESETS"))

;; the status column carries the only colour that matters. OFF is where
;; this row's line starts, which the list hands us — the glyph is three
;; bytes wide, and an overlay ending mid-character renders as mojibake
;; rather than as colour.
(define (mcp-hub-overlays name off)
  (let* ((row (mcp-hub-row name))
         (g-end (+ off (string-byte-length (mcp-hub-glyph (cadr row)))))
         (n-start (+ g-end 1))
         (n-end (+ n-start (string-byte-length (mcp-hub-fit (car row) 16))))
         (s-start (+ n-end 7))              ; space + type column + space
         (s-end (+ s-start (string-byte-length (cadr row)))))
    (list (list off g-end (mcp-hub-status-face (cadr row)))
          (list n-start n-end "mcp-name")
          (list s-start s-end (mcp-hub-status-face (cadr row))))))

(define (mcp-hub-refresh!) (list-refresh! *mcp-hub-buffer*))

;; a connection changing state redraws the list, if anyone is looking
(mcp-on-change! (lambda (name status) (mcp-hub-refresh!)))

(define (mcp-hub-current) (list-current *mcp-hub-buffer*))

;;; --- start, stop, restart -----------------------------------------------------

(define (mcp-hub-start! name)
  (mcp-ensure! (string->symbol name))
  (mcp-hub-refresh!))

(define (mcp-hub-stop! name)
  (mcp-disconnect! name)
  (mcp-hub-refresh!))

;; stop is synchronous (the supervisor takes the child down before it
;; returns), so starting straight after is a genuine restart, not a race
(define (mcp-hub-restart! name)
  (mcp-disconnect! name)
  (mcp-hub-start! name))

(define (mcp-hub-on-current fn)
  (let ((name (mcp-hub-current)))
    (if name (fn name) (message "no server on this line"))))

(define-command "mcp-hub-start" "Start the MCP server on this line"
  (lambda () (mcp-hub-on-current mcp-hub-start!)))

(define-command "mcp-hub-stop" "Stop the MCP server on this line"
  (lambda () (mcp-hub-on-current mcp-hub-stop!)))

(define-command "mcp-hub-restart" "Restart the MCP server on this line"
  (lambda () (mcp-hub-on-current mcp-hub-restart!)))

(define-command "mcp-hub-start-all" "Start every registered MCP server"
  (lambda ()
    (for-each mcp-hub-start! (mcp-hub-names))
    (message "starting every registered server")))

(define-command "mcp-hub-stop-all" "Stop every running MCP server"
  (lambda ()
    (for-each (lambda (c) (mcp-disconnect! (car c))) (mcp-connections))
    (mcp-hub-refresh!)
    (message "all servers stopped")))

(define-command "mcp-hub-restart-all" "Restart every running MCP server"
  (lambda ()
    (for-each (lambda (c) (mcp-hub-restart! (car c))) (mcp-connections))
    (message "restarting")))

(define-command "mcp-hub-refresh" "Redraw the server list"
  (lambda () (mcp-hub-refresh!)))

;;; --- what a server serves -----------------------------------------------------

;; appends one titled section and returns OVS with its ranges on top —
;; sections are written in sequence, so each needs the running list
(define (mcp-hub-section buf title items render ovs)
  (let ((head (string-append title " (" (number->string (length items)) ")\n")))
    (let ((start (buffer-size buf)))
      (buffer-append! buf head)
      (let loop ((is items) (off (+ start (string-byte-length head))) (ovs ovs))
        (if (null? is)
            (begin (buffer-append! buf "\n")
                   (cons (list start (+ start (string-byte-length title)) "mcp-heading")
                         ovs))
            (let* ((text (render (car is)))
                   (name (car text))
                   (desc (cadr text))
                   (line (string-append "  • " name "\n"))
                   (body (if (equal? desc "")
                             ""
                             (string-append "    " desc "\n")))
                   ;; "  • " is six bytes — the bullet is three of them
                   (n-start (+ off 6))
                   (n-end (+ n-start (string-byte-length name))))
              (buffer-append! buf (string-append line body))
              (loop (cdr is)
                    (+ off (string-byte-length line) (string-byte-length body))
                    (cons (list n-start n-end "mcp-item")
                          (if (equal? body "")
                              ovs
                              (cons (list (+ n-end 5)      ; newline + "    "
                                          (+ n-end (string-byte-length body))
                                          "mcp-dim")
                                    ovs))))))))))

(define (mcp-hub-detail-buffer name)
  (string-append "*mcp: " name "*"))

(define (mcp-hub-render-detail! buf name)
  (let ((d (mcp-server-detail name)))
    (if (not d)
        ;; restored from a previous session, or never run: the old text is a
        ;; frozen screenshot of a server that isn't there — say so instead
        (begin
          (buffer-set-read-only! buf #f)
          (buffer-delete-range! buf 0 (buffer-size buf))
          (buffer-append! buf
            (string-append name " — not started\n\n"
                           "(s on its row in " *mcp-hub-buffer* " starts it)\n"))
          (overlay-set! buf 'mcp-detail
            (list (list 0 (string-byte-length name) "mcp-heading")))
          (buffer-set-read-only! buf #t))
        (let* ((title (string-append name " — " (plist-get d 'type) ", "
                                     (plist-get d 'status) "\n"))
               (ident (let ((sn (plist-get d 'server-name)))
                        (if (equal? sn "")
                            ""
                            (string-append sn " " (plist-get d 'server-version) "\n"))))
              (why (let ((r (plist-get d 'reason)))
                     (if (equal? r "") "" (string-append r "\n")))))
          (buffer-create buf)
          (buffer-set-read-only! buf #f)
          (buffer-delete-range! buf 0 (buffer-size buf))
          (buffer-append! buf (string-append title ident why "\n"))
          (let* ((ovs (mcp-hub-section buf "Tools" (plist-get d 'tools)
                        (lambda (t) (list (car t) (cadr t)))
                        '()))
                 (ovs (mcp-hub-section buf "Resources" (plist-get d 'resources)
                        (lambda (r)
                          (list (string-append (car r) " (" (cadr r) ")")
                                (caddr r)))
                        ovs))
                 (ovs (mcp-hub-section buf "Prompts" (plist-get d 'prompts)
                        (lambda (p) (list (car p) (cadr p)))
                        ovs)))
            (overlay-set! buf 'mcp-detail
              (cons (list 0 (string-byte-length name) "mcp-heading") ovs)))
          (buffer-set-read-only! buf #t)))))

;; the setup fn is the whole buffer: keys AND content rebuilt from the one
;; local that says which server this is, so a restored buffer comes back
;; live rather than as a frozen screenshot of a dead session
(define (mcp-hub-detail-setup! buf)
  (let ((name (buffer-local buf 'mcp-hub-name)))
    (local-set-key* buf "g" "mcp-hub-detail-refresh")
    (local-set-key* buf "l" "mcp-hub-detail-log")
    (local-set-key* buf "q" "quit-window")
    (when name (mcp-hub-render-detail! buf name))))

(define-mode "mcp-detail-mode" (lambda () (mcp-hub-detail-setup! (current-buffer))))

(define (mcp-hub-show-detail name)
  (if (not (mcp-server-detail name))
      (message (string-append name " has never been started — s starts it"))
      (let ((buf (mcp-hub-detail-buffer name)))
        (buffer-create buf)
        (buffer-set-local! buf 'mcp-hub-name name)
        (buffer-set-local! buf 'mode-name "mcp-detail-mode")
        (mcp-hub-detail-setup! buf)
        (display-buffer buf))))

(define-command "mcp-hub-detail" "Show what the server on this line serves"
  (lambda () (mcp-hub-on-current mcp-hub-show-detail)))

(define-command "mcp-hub-detail-refresh" "Re-read this server's tools"
  (lambda ()
    (let ((name (buffer-local (current-buffer) 'mcp-hub-name)))
      (when name (mcp-hub-render-detail! (current-buffer) name)))))

;;; --- the wire ------------------------------------------------------------------

(define (mcp-hub-dir-glyph dir)
  (cond ((equal? dir "out") "→")
        ((equal? dir "in") "←")
        (else "·")))

;; stderr is not in here: a stdio server's diagnostics go to the daemon's
;; own stderr (~/.aimax/daemon.log), and merging them into this stream
;; risks interleaving a half-written line into a JSON frame.
(define (mcp-hub-render-log! buf name)
  (let ((entries (mcp-log name)))
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf
      (string-append ";; " name " — JSON-RPC frames, oldest first"
                     " (server stderr goes to ~/.aimax/daemon.log)\n"))
    (if (null? entries)
        (buffer-append! buf "\n(nothing yet — this server has not been started)\n")
        (for-each
          (lambda (e)
            (buffer-append! buf
              (string-append (car e) " " (mcp-hub-dir-glyph (cadr e)) " "
                             (caddr e) "\n")))
          entries))
    (buffer-set-read-only! buf #t)))

(define (mcp-hub-log-setup! buf)
  (let ((name (buffer-local buf 'mcp-hub-name)))
    (local-set-key* buf "g" "mcp-hub-log-refresh")
    (local-set-key* buf "q" "quit-window")
    (when name (mcp-hub-render-log! buf name))))

(define-mode "mcp-log-mode" (lambda () (mcp-hub-log-setup! (current-buffer))))

(define (mcp-hub-show-log name)
  (let ((buf (string-append "*mcp-log: " name "*")))
    (buffer-create buf)
    (buffer-set-local! buf 'mcp-hub-name name)
    (buffer-set-local! buf 'mode-name "mcp-log-mode")
    (mcp-hub-log-setup! buf)
    (display-buffer buf)))

(define-command "mcp-hub-log" "Show the JSON-RPC frames for the server on this line"
  (lambda () (mcp-hub-on-current mcp-hub-show-log)))

(define-command "mcp-hub-log-refresh" "Re-read this server's frames"
  (lambda ()
    (let ((name (buffer-local (current-buffer) 'mcp-hub-name)))
      (when name (mcp-hub-render-log! (current-buffer) name)))))

;; from a detail buffer, l opens that server's log
(define-command "mcp-hub-detail-log" "Show this server's frames"
  (lambda ()
    (let ((name (buffer-local (current-buffer) 'mcp-hub-name)))
      (when name (mcp-hub-show-log name)))))

;;; --- the hub -------------------------------------------------------------------

(define-list-mode! "mcp-hub-mode"
  (list
    'buffer *mcp-hub-buffer*
    'rows mcp-hub-names
    'render (lambda (name) (mcp-hub-line (mcp-hub-row name)))
    'header mcp-hub-header
    'overlays mcp-hub-overlays
    'keys '(("RET" "mcp-hub-detail") ("d" "mcp-hub-detail") ("s" "mcp-hub-start")
            ("k" "mcp-hub-stop") ("r" "mcp-hub-restart") ("S" "mcp-hub-start-all")
            ("K" "mcp-hub-stop-all") ("R" "mcp-hub-restart-all")
            ("l" "mcp-hub-log") ("g" "mcp-hub-refresh") ("q" "quit-window"))))

(define-command "mcp-hub" "List every MCP server: status, tools, presets"
  (lambda () (list-mode-show! "mcp-hub-mode")))

(global-set-key "C-c a m" "mcp-hub")

(category! 'mcp)
(public! 'mcp-hub-refresh! "(mcp-hub-refresh!) — redraw *mcp-hub* if it exists")
(public! 'mcp-server-detail "(mcp-server-detail NAME) — plist: status, type, tools, resources, prompts")
(public! 'mcp-log "(mcp-log NAME) — ((time dir text) ...) JSON-RPC frames, oldest first")
