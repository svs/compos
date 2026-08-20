;;; lsp.scm --- language servers: registry, lsp-mode, diagnostics.
;;;
;;; Policy over the Aimax.Core.LSP mechanism. A server registers per
;;; mode; a mode hook attaches file buffers in a project to one server
;;; per (server, project-root). Diagnostics paint as underline overlays,
;;; count in the modeline, and list in a bottom sheet.
;;;
;;; The Elixir side owns transport, document sync, and position
;;; encoding: every diagnostic and location arrives with startByte and
;;; endByte already computed for open buffers.

(package! 'lsp)
(category! 'code)
(domain! 'code)
(effects! '(write external execute))

;;; --- registry ----------------------------------------------------------------

(define *lsp-registry* '())      ; ((name spec) ...); spec plist has 'modes
(define *lsp-hooked-modes* '())  ; modes that already carry the attach hook
(define *lsp-attempted* '())     ; ids tried once — a dead server is not respawned per keystroke

(define (lsp--id name root) (string-append name "@" root))

(define (lsp--id-name id) (car (string-split id "@")))

(define (lsp-register! name spec)
  (set! *lsp-registry*
    (cons (list name spec)
          (remove (lambda (e) (equal? (car e) name)) *lsp-registry*)))
  (for-each
    (lambda (mode)
      (unless (member mode *lsp-hooked-modes*)
        (set! *lsp-hooked-modes* (cons mode *lsp-hooked-modes*))
        (add-hook! (string->symbol (string-append mode "-hook")) lsp--maybe-attach!)))
    (or (plist-get spec 'modes) '()))
  name)

(define (lsp-server-for-mode mode)
  (let loop ((es *lsp-registry*))
    (cond ((null? es) #f)
          ((member mode (or (plist-get (cadr (car es)) 'modes) '())) (car es))
          (else (loop (cdr es))))))

;; Start NAME for ROOT once. The connection reports its own failure;
;; this only stops a retry storm.
(define (lsp-ensure! name root)
  (let ((id (lsp--id name root)))
    (unless (member id *lsp-attempted*)
      (set! *lsp-attempted* (cons id *lsp-attempted*))
      (let ((e (assoc name *lsp-registry*)))
        (when e (lsp-start! name root (cadr e)))))
    id))

(define (lsp--connection? id) (assoc id (lsp-connections)))

;;; --- attach ------------------------------------------------------------------

(define (lsp--maybe-attach!)
  (let ((buf (current-buffer)))
    (when (and lsp-auto-start (buffer-path buf))
      (let ((entry (lsp-server-for-mode (buffer-local buf 'mode-name)))
            (root (buffer-project-root buf)))
        (when (and entry root (not (equal? root "")))
          (buffer-set-local! buf 'lsp-server (lsp-ensure! (car entry) root))
          (enable-minor-mode! buf "lsp-mode"))))))

(define (lsp--setup! buf)
  (desktop-skip! buf 'lsp-diagnostics)
  (let ((id (buffer-local buf 'lsp-server)))
    (when id
      ;; after a restart the server is gone: start it again from the id
      (let ((parts (string-split id "@")))
        (when (= (length parts) 2)
          (lsp-ensure! (car parts) (cadr parts))))
      (when (lsp--connection? id)
        (lsp-open! id buf))
      (desktop-skip! buf 'capf-sources)
      (let ((cur (or (buffer-local buf 'capf-sources) '())))
        (unless (member lsp--capf cur)
          (buffer-set-local! buf 'capf-sources (cons lsp--capf cur))))
      (lsp--modeline! buf))))

(define (lsp--teardown! buf)
  (let ((id (buffer-local buf 'lsp-server)))
    (when (and id (lsp--connection? id))
      (lsp-close! id buf)))
  (buffer-set-local! buf 'capf-sources
    (remove (lambda (f) (equal? f lsp--capf))
            (or (buffer-local buf 'capf-sources) '())))
  (overlay-clear! buf 'lsp)
  (buffer-set-local! buf 'lsp-diagnostics #f)
  (buffer-set-local! buf 'lsp-server #f)
  (buffer-set-local! buf 'modeline-info #f))

(register-minor-mode! "lsp-mode" lsp--setup! lsp--teardown!)

(define-command "lsp-mode" "Toggle the language server for this buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (minor-mode-on? buf "lsp-mode")
          (begin (disable-minor-mode! buf "lsp-mode") (message "lsp-mode disabled"))
          (let ((entry (lsp-server-for-mode (buffer-local buf 'mode-name)))
                (root (buffer-project-root buf)))
            (cond ((not entry) (message "No language server registered for this mode"))
                  ((equal? root "") (message "No project root for this buffer"))
                  (else
                   (buffer-set-local! buf 'lsp-server (lsp-ensure! (car entry) root))
                   (enable-minor-mode! buf "lsp-mode")
                   (message "lsp-mode enabled"))))))))

;;; --- events ------------------------------------------------------------------

(define (lsp--status! id status)
  (for-each
    (lambda (buf)
      (when (equal? (buffer-local buf 'lsp-server) id)
        (if (equal? status "ready")
            (when (minor-mode-on? buf "lsp-mode")
              (lsp-open! id buf)
              (lsp--modeline! buf))
            (lsp--modeline! buf))))
    (buffer-list)))

(define *lsp-severity-faces*
  '((1 "lsp-error") (2 "lsp-warning") (3 "lsp-info") (4 "lsp-hint")))

(define (lsp--face sev)
  (let ((e (assoc (or sev 1) *lsp-severity-faces*)))
    (if e (cadr e) "lsp-info")))

(define (lsp--diagnostics! id params)
  (let ((buf (plist-get params 'buffer))
        (diags (or (plist-get params 'diagnostics) '())))
    (when (and buf (buffer-exists? buf))
      (buffer-set-local! buf 'lsp-diagnostics diags)
      (overlay-set! buf 'lsp
        (map (lambda (d)
               (list (or (plist-get d 'startByte) 0)
                     (or (plist-get d 'endByte) 0)
                     (lsp--face (plist-get d 'severity))))
             diags))
      (lsp--modeline! buf)
      (when (buffer-exists? *lsp-diag-buffer*)
        (list-refresh! *lsp-diag-buffer*)))))

;; lsp-on-event! is a single slot; this package owns it and fans out.
;; Add a listener with (on-lsp-event! NAME FN) — same name replaces.
(define *lsp-event-handlers* '())

(define (on-lsp-event! name fn)
  (set! *lsp-event-handlers*
    (cons (list name fn)
          (remove (lambda (e) (equal? (car e) name)) *lsp-event-handlers*))))

(lsp-on-event!
  (lambda (id method params)
    (cond ((equal? method "textDocument/publishDiagnostics")
           (lsp--diagnostics! id params))
          ((equal? method "aimax/status")
           (lsp--status! id (plist-get params 'status)))
          ((equal? method "window/showMessage")
           (message (string-append "lsp: " (or (plist-get params 'message) ""))))
          (else #f))
    (for-each (lambda (e) ((cadr e) id method params)) *lsp-event-handlers*)))

(public! 'on-lsp-event!
  "(on-lsp-event! NAME FN) — add a named listener for (ID METHOD PARAMS) server events")

(define-style! 'lsp "
.f-lsp-error{text-decoration:underline wavy var(--alert-fg,#a83a2b);text-decoration-skip-ink:none}
.f-lsp-warning{text-decoration:underline wavy var(--warn-fg,#7a5a1a);text-decoration-skip-ink:none}
.f-lsp-info{text-decoration:underline dotted var(--accent-fg,#4a6a8a)}
.f-lsp-hint{text-decoration:underline dotted var(--faint-fg,#8a8a86)}
")

;;; --- modeline ----------------------------------------------------------------

(define (lsp--counts buf)
  (let loop ((ds (or (buffer-local buf 'lsp-diagnostics) '())) (e 0) (w 0))
    (if (null? ds)
        (list e w)
        (let ((sev (or (plist-get (car ds) 'severity) 1)))
          (loop (cdr ds)
                (if (= sev 1) (+ e 1) e)
                (if (= sev 2) (+ w 1) w))))))

(define (lsp--modeline! buf)
  (let* ((id (buffer-local buf 'lsp-server))
         (row (and id (assoc id (lsp-connections))))
         (c (lsp--counts buf)))
    (when id
      (buffer-set-local! buf 'modeline-info
        (string-append (lsp--id-name id)
          ;; elixir-ls compiles for a while after the handshake: an
          ;; ellipsis says the server is not answering yet
          (cond ((not row) " off")
                ((equal? (cadr row) "ready") "")
                (else "…"))
          (if (> (car c) 0) (string-append " ✗" (number->string (car c))) "")
          (if (> (cadr c) 0) (string-append " ⚠" (number->string (cadr c))) "")))
      (buffer-set-local! buf 'modeline-info-command "lsp-diagnostics-list"))))

;;; --- diagnostics at point, next/prev -----------------------------------------

;; (sort LST) has no comparator: sort (START DIAG) pairs by term order
(define (lsp--diags-sorted buf)
  (map cadr
       (sort (map (lambda (d) (list (or (plist-get d 'startByte) 0) d))
                  (or (buffer-local buf 'lsp-diagnostics) '())))))

(define (lsp--sev-name sev)
  (cond ((equal? sev 1) "error")
        ((equal? sev 2) "warning")
        ((equal? sev 3) "info")
        (else "hint")))

(define (lsp--echo-diag d)
  (message (string-append
             "lsp · " (lsp--sev-name (or (plist-get d 'severity) 1))
             " — " (or (plist-get d 'message) ""))))

(define-command "lsp-next-diagnostic" "Move to the next diagnostic"
  (lambda ()
    (let* ((buf (current-buffer)) (p (point))
           (hit (let loop ((ds (lsp--diags-sorted buf)))
                  (cond ((null? ds) #f)
                        ((> (or (plist-get (car ds) 'startByte) 0) p) (car ds))
                        (else (loop (cdr ds)))))))
      (if hit
          (begin (goto-char! (plist-get hit 'startByte)) (lsp--echo-diag hit))
          (message "No next diagnostic")))))

(define-command "lsp-prev-diagnostic" "Move to the previous diagnostic"
  (lambda ()
    (let* ((buf (current-buffer)) (p (point))
           (hit (let loop ((ds (lsp--diags-sorted buf)) (last #f))
                  (cond ((null? ds) last)
                        ((< (or (plist-get (car ds) 'startByte) 0) p)
                         (loop (cdr ds) (car ds)))
                        (else last)))))
      (if hit
          (begin (goto-char! (plist-get hit 'startByte)) (lsp--echo-diag hit))
          (message "No previous diagnostic")))))

(define-command "lsp-show-diagnostic" "Echo the diagnostic at point"
  (lambda ()
    (let* ((buf (current-buffer)) (p (point))
           (hit (let loop ((ds (or (buffer-local buf 'lsp-diagnostics) '())))
                  (cond ((null? ds) #f)
                        ((and (<= (or (plist-get (car ds) 'startByte) 0) p)
                              (<= p (or (plist-get (car ds) 'endByte) 0)))
                         (car ds))
                        (else (loop (cdr ds)))))))
      (if hit (lsp--echo-diag hit) (message "No diagnostic at point")))))

;;; --- the diagnostics list ----------------------------------------------------

(define *lsp-diag-buffer* "*diagnostics*")

(define (lsp--diag-line buf d)
  (let ((start (or (plist-get d 'startByte) 0)))
    (length (string-split (substring-bytes (buffer-text buf) 0
                                           (min start (buffer-size buf)))
                          "\n"))))

(define (lsp--diag-rows list-buf)
  (apply append
    (map (lambda (buf)
           (map (lambda (d)
                  (list 'buf buf
                        'line (lsp--diag-line buf d)
                        'sev (or (plist-get d 'severity) 1)
                        'msg (or (plist-get d 'message) "")
                        'start (or (plist-get d 'startByte) 0)))
                (or (buffer-local buf 'lsp-diagnostics) '())))
         (filter (lambda (b) (buffer-local b 'lsp-diagnostics)) (buffer-list)))))

(define (lsp--diag-visit e select?)
  (let ((buf (plist-get e 'buf)))
    (when (buffer-exists? buf)
      (if select?
          (switch-to-buffer! buf)
          (window-preview-buffer! buf))
      (buffer-goto! buf (plist-get e 'start)))))

(define-list-mode! "lsp-diagnostics-mode"
  (list
    'doc "Every open buffer's language-server diagnostics."
    'buffer *lsp-diag-buffer*
    'rows lsp--diag-rows
    'key (lambda (buf e)
           (string-append (plist-get e 'buf) ":"
                          (number->string (plist-get e 'start)) ":"
                          (plist-get e 'msg)))
    'columns (lambda (buf)
               (list (list "sev" 7)
                     (list "buffer" 28)
                     (list "line" 5 'right)
                     (list "message" #f)))
    'cells (lambda (buf e)
             (list (lsp--sev-name (plist-get e 'sev))
                   (buffer-short-label (plist-get e 'buf))
                   (number->string (plist-get e 'line))
                   (plist-get e 'msg)))
    'title (lambda (buf) "Diagnostics")
    'noun "diagnostic"
    'preview (lambda (buf e) (lsp--diag-visit e #f))
    'keys '(("RET" "lsp-diag-visit")
            ("g" "lsp-diag-refresh")
            ("q" "quit-window"))))

(add-display-rule! *lsp-diag-buffer* 'popup '(side bottom size 0.32))

(define-command "lsp-diag-visit" "Visit the diagnostic on this row"
  (lambda ()
    (let ((e (list-current (current-buffer))))
      (when e (lsp--diag-visit e #t)))))

(define-command "lsp-diag-refresh" "Refresh the diagnostics list"
  (lambda () (list-refresh! *lsp-diag-buffer*)))

(define-command "lsp-diagnostics-list" "Show diagnostics as a list"
  (lambda () (list-mode-show! "lsp-diagnostics-mode")))

;;; --- navigation: definition, references, hover -------------------------------

(define *lsp-marker-stack* '())   ; ((buffer point) ...), newest first

(define (lsp--cap lst n)
  (if (or (null? lst) (= n 0))
      '()
      (cons (car lst) (lsp--cap (cdr lst) (- n 1)))))

(define (lsp--push-marker!)
  (set! *lsp-marker-stack*
    (lsp--cap (cons (list (current-buffer) (point)) *lsp-marker-stack*) 32)))

(define-command "lsp-pop-marker" "Return to where the last jump started"
  (lambda ()
    (if (null? *lsp-marker-stack*)
        (message "No marker to pop")
        (let ((m (car *lsp-marker-stack*)))
          (set! *lsp-marker-stack* (cdr *lsp-marker-stack*))
          (if (buffer-known? (car m))
              (begin (switch-to-buffer! (car m)) (goto-char! (cadr m)))
              (message "That buffer is gone"))))))

;; Location | Location[] | LocationLink[] -> a list of location plists
(define (lsp--locs result)
  (cond ((not result) '())
        ((null? result) '())
        ((symbol? (car result)) (list result))
        (else result)))

(define (lsp--loc-uri loc)
  (or (plist-get loc 'uri) (plist-get loc 'targetUri)))

(define (lsp--loc-path loc)
  (let ((u (lsp--loc-uri loc)))
    (and u (string-prefix? "file://" u)
         (substring u 7 (string-length u)))))

(define (lsp--loc-range loc)
  (or (plist-get loc 'targetSelectionRange)
      (plist-get loc 'range)
      (plist-get loc 'targetRange)))

(define (lsp--loc-line loc)
  (let ((r (lsp--loc-range loc)))
    (if r (+ 1 (or (plist-get (or (plist-get r 'start) '()) 'line) 0)) 1)))

;; Show a location: an open buffer jumps by byte offset; a file on disk
;; opens by path and line (the rg--show pattern).
(define (lsp--show-loc! loc select?)
  (let ((buf (plist-get loc 'buffer))
        (start (plist-get loc 'startByte))
        (path (lsp--loc-path loc)))
    (cond ((and buf start (buffer-exists? buf))
           (if select? (switch-to-buffer! buf) (window-preview-buffer! buf))
           (buffer-goto! buf start)
           (when select? (goto-char! start)))
          (path
           (if select?
               (visit path)
               (window-preview-buffer! (find-file path)))
           (goto-char! (line-start-position (lsp--loc-line loc))))
          (else (message "lsp: location without a place")))))

(define (lsp--loc-label loc)
  (string-append
    (buffer-short-label (or (plist-get loc 'buffer) (lsp--loc-path loc) "?"))
    ":" (number->string (lsp--loc-line loc))))

(define (lsp--pick-loc! prompt locs)
  (let ((by-label (map (lambda (l) (list (lsp--loc-label l) l)) locs)))
    (minibuffer-read-preview prompt
      (map (lambda (e) (list (car e) "")) by-label)
      (lambda (label)
        (let ((hit (assoc label by-label)))
          (when hit (lsp--show-loc! (cadr hit) #f))))
      (lambda (label)
        (let ((hit (assoc label by-label)))
          (when hit (lsp--show-loc! (cadr hit) #t))))
      (lambda () #f))))

;; Bound the moment this file loads: code.scm's M-. seam calls it when a
;; server is attached (SYM is echoed, the position does the asking).
(define (lsp-definition sym)
  (let* ((buf (current-buffer))
         (id (buffer-local buf 'lsp-server)))
    (if (not id)
        (message "No language server here")
        (lsp-buffer-request id "textDocument/definition" buf (point)
          (lambda (ok result)
            (let ((locs (if ok (lsp--locs result) '())))
              (cond ((not ok) (message (string-append "lsp: " result)))
                    ((null? locs)
                     (message (string-append "No definition of " sym)))
                    ((null? (cdr locs))
                     (lsp--push-marker!)
                     (lsp--show-loc! (car locs) #t))
                    (else
                     (lsp--push-marker!)
                     (lsp--pick-loc! "Definition: " locs)))))))))

;;; references

(define *lsp-refs* '())          ; the last references result
(define *lsp-ref-buffer* "*references*")

(define (lsp--ref-rows list-buf) *lsp-refs*)

(define-list-mode! "lsp-references-mode"
  (list
    'doc "Places that reference the symbol the last lsp-references asked about."
    'buffer *lsp-ref-buffer*
    'rows lsp--ref-rows
    'key (lambda (buf loc) (lsp--loc-label loc))
    'columns (lambda (buf) (list (list "where" 40) (list "line" 5 'right)))
    'cells (lambda (buf loc)
             (list (buffer-short-label
                     (or (plist-get loc 'buffer) (lsp--loc-path loc) "?"))
                   (number->string (lsp--loc-line loc))))
    'title (lambda (buf) "References")
    'noun "reference"
    'preview (lambda (buf loc) (lsp--show-loc! loc #f))
    'keys '(("RET" "lsp-ref-visit")
            ("q" "quit-window"))))

(add-display-rule! *lsp-ref-buffer* 'popup '(side bottom size 0.32))

(define-command "lsp-ref-visit" "Visit the reference on this row"
  (lambda ()
    (let ((loc (list-current (current-buffer))))
      (when loc (lsp--push-marker!) (lsp--show-loc! loc #t)))))

(define-command "lsp-references" "List the references to the symbol at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (id (buffer-local buf 'lsp-server)))
      (if (not id)
          (message "No language server here")
          (lsp-buffer-request id "textDocument/references" buf (point)
            (list 'context (list 'includeDeclaration #t))
            (lambda (ok result)
              (let ((locs (if ok (lsp--locs result) '())))
                (cond ((not ok) (message (string-append "lsp: " result)))
                      ((null? locs) (message "No references"))
                      (else
                       (set! *lsp-refs* locs)
                       (list-mode-show! "lsp-references-mode"))))))))))

;;; hover

(define (lsp--hover-text c)
  (cond ((not c) #f)
        ((string? c) c)
        ((null? c) #f)
        ((symbol? (car c)) (or (plist-get c 'value) #f))
        (else (lsp--hover-text (car c)))))

;; the echo area holds one line: the first non-empty line of the hover
(define (lsp--first-line s)
  (let loop ((ls (string-split s "\n")))
    (cond ((null? ls) "")
          ((equal? (string-trim (car ls)) "") (loop (cdr ls)))
          (else (string-trim (car ls))))))

(define-command "lsp-hover" "Echo the type or documentation at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (id (buffer-local buf 'lsp-server)))
      (if (not id)
          (message "No language server here")
          (lsp-buffer-request id "textDocument/hover" buf (point)
            (lambda (ok result)
              (let ((text (and ok result
                               (lsp--hover-text (plist-get result 'contents)))))
                (if (and text (not (equal? text "")))
                    (message (lsp--first-line text))
                    (message "No documentation here")))))))))

;;; --- completion --------------------------------------------------------------
;;; The capf source answers #f and asks the server; the reply raises the
;;; popup itself (completion-show! is callable from a callback). Until
;;; it lands, the next source — dabbrev — fills the popup.

(define (lsp--completion-items result)
  (let ((items (cond ((not result) '())
                     ((null? result) '())
                     ((symbol? (car result)) (or (plist-get result 'items) '()))
                     (else result))))
    (lsp--cap
      (map cadr
           (sort (map (lambda (it)
                        (list (or (plist-get it 'sortText) (plist-get it 'label) "")
                              (list (or (plist-get it 'label) "")
                                    (or (plist-get it 'detail) "lsp"))))
                      items)))
      80)))

(define (lsp--capf)
  (let* ((buf (current-buffer))
         (id (buffer-local buf 'lsp-server)))
    (if (or (not id) (not (lsp--connection? id)))
        #f
        (let* ((e (point))
               (s (let ((s (backward-word!))) (goto-char! e) (min s e))))
          (lsp-buffer-request id "textDocument/completion" buf e
            (lambda (ok result)
              (when (and ok (equal? (current-buffer) buf) (>= (point) s))
                (let ((cands (lsp--completion-items result)))
                  (unless (null? cands)
                    (completion-show! s (point) cands))))))
          #f))))

;;; save notification

(add-hook! 'after-save-hook
  (lambda ()
    (let* ((buf (current-buffer))
           (id (buffer-local buf 'lsp-server)))
      (when (and id (minor-mode-on? buf "lsp-mode") (lsp--connection? id))
        (lsp-notify! id "textDocument/didSave"
          (list 'textDocument
                (list 'uri (string-append "file://" buf))))))))

(global-set-key "M-." "code-goto-definition")
(global-set-key "M-," "lsp-pop-marker")

;;; --- status ------------------------------------------------------------------

(define-command "lsp-status" "Echo every language-server connection"
  (lambda ()
    (let ((cs (lsp-connections)))
      (if (null? cs)
          (message "lsp: no connections")
          (message (string-join
                     (map (lambda (c) (string-append (car c) " " (cadr c))) cs)
                     " · "))))))

;;; --- configuration and default servers ---------------------------------------

(defgroup 'lsp "Language server client.")

(defcustom 'lsp-auto-start #t
  "Start a language server when a visited file's mode has one."
  'group 'lsp 'type 'boolean)

(lsp-register! "elixir-ls"
  (list 'command "elixir-ls" 'language "elixir" 'modes (list "elixir-mode")))

(lsp-register! "typescript-language-server"
  (list 'command "typescript-language-server" 'args (list "--stdio")
        'language "javascript" 'modes (list "js-mode")))

(lsp-register! "ruby-lsp"
  (list 'command "ruby-lsp" 'language "ruby" 'modes (list "ruby-mode")))

;; scheme-langserver speaks r6rs; it reads .scm but knows none of the
;; aimax vocabulary. The durable scheme story is a built-in provider
;; over the catalog (v2).
(lsp-register! "scheme-langserver"
  (list 'command "scheme-langserver" 'language "scheme" 'modes (list "scheme-mode")))

(public! 'lsp-register!
  "(lsp-register! NAME SPEC) — register a language server; SPEC has 'command 'args 'env 'language 'modes 'settings")
(public! 'lsp-ensure!
  "(lsp-ensure! NAME ROOT) — start the registered server for ROOT once; return the connection id")
