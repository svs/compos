;;; doppler.scm --- secrets lookup over the doppler CLI, userland Scheme.
;;;
;;; No Elixir knows what Doppler is. Same shape as notmuch.scm: shell out
;;; to the `doppler` CLI (already authenticated via `doppler login` on
;;; this machine) and parse --json output. The list app never fetches values.
;;; A copy or set command handles one explicit value at a time.
;;;
;;; Secret VALUES are sensitive and land in the chat transcript once
;;; printed — dp--secret-names never asks the CLI for values at all
;;; (--only-names), and dp-secret-get is a separate, explicit call so a
;;; value only ever shows up when someone asks for that exact secret.

(domain! 'secrets)
(effects! '(write))

(defgroup 'doppler "Secrets: Doppler CLI lookups and secret management.")

(defcustom 'doppler-program "doppler"
  "The doppler executable." 'group 'doppler)

;; The key chain's Doppler source: which project/config the chain reads.
;; keys.scm asks for a key by name and never knows Doppler is behind it.
(defcustom 'key-doppler-project "personal"
  "The Doppler project the key chain reads." 'group 'doppler)

(defcustom 'key-doppler-config "dev"
  "The Doppler config the key chain reads." 'group 'doppler)

(define *doppler-buffer* "*doppler*")
(define *doppler-group* "doppler")

;;; --- CLI plumbing -------------------------------------------------------------

(define (dp--quote s)
  (string-append "'" (string-join (string-split s "'") "'\\''") "'"))

(define (dp--run args)
  (shell-command->string (string-append (dp--quote doppler-program) " " args)))

(define (dp--json args)
  (json-parse (dp--run (string-append args " --json"))))

(define (dp--error? out)
  (or (string-contains? out "Doppler Error")
      (string-contains? out "Error:")))

(define (dp--projects-data)
  (or (dp--json "projects") '()))

(define (dp--configs-data project)
  (or (dp--json (string-append "configs --project " (dp--quote project))) '()))

(define (dp--secret-name-list project config)
  (sort
    (map symbol->string
      (dp--plist-keys
        (or (dp--json (string-append "secrets --project " (dp--quote project)
                                     " --config " (dp--quote config)
                                     " --only-names"))
            '())))))

;;; --- lookups for the model ----------------------------------------------------

(define (doppler-projects)
  (let ((ps (dp--projects-data)))
    (if (null? ps)
        "no projects"
        (fold (lambda (acc p)
                (string-append acc (custom--plist-get p 'name)
                  (let ((d (custom--plist-get p 'description)))
                    (if (and d (not (equal? d ""))) (string-append " — " d) ""))
                  "\n"))
              "" ps))))

(define (doppler-configs project)
  (let ((cs (dp--configs-data project)))
    (if (null? cs)
        (string-append "no configs (or no such project: " project ")")
        (fold (lambda (acc c)
                (string-append acc (custom--plist-get c 'name) "  ("
                  (or (custom--plist-get c 'environment) "") ")\n"))
              "" cs))))

;; every other key of a flat plist (k1 v1 k2 v2 ...) — json-parse turns a
;; JSON object into exactly this shape
(define (dp--plist-keys pl)
  (if (null? pl) '() (cons (car pl) (dp--plist-keys (cddr pl)))))

;; names only — never asks the CLI for values, so this is safe to print
;; straight into a chat transcript. `doppler secrets --only-names --json`
;; returns {"NAME": {}, ...} — json-parse flattens that to a plist whose
;; keys ARE the secret names
(define (doppler-secret-names project config)
  (let ((names (dp--secret-name-list project config)))
    (if (null? names)
        (string-append "no secrets (or no such project/config: " project "/" config ")")
        (string-join names "\n"))))

;; the one call that returns an actual secret value, or #f when the
;; project, the config, or the name does not exist. The CLI writes its
;; errors to stderr and dp--run folds those in, so a failure arrives as
;; text and not as a status — read it back out. packages/keys.scm calls
;; this as the last link of the key chain.
;; One doppler process per secret for the whole session — the policy
;; key-get documents for the chain, applied at the source so every
;; consumer gets it (sentry resolves its token per request, and the CLI
;; cost ~500ms on the UI lane per fetch). Misses cache too. A write
;; drops its own entry; doppler-forget! drops them all.
(define *dp-value-cache* '())

(define (dp--cache-key project config name)
  (string-append project "/" config "/" name))

(define (dp--cache-drop! project config name)
  (let ((key (dp--cache-key project config name)))
    (set! *dp-value-cache*
      (remove (lambda (e) (equal? (car e) key)) *dp-value-cache*))))

(define (doppler-forget!)
  (set! *dp-value-cache* '())
  (set! *dp-config-warmed* '()))

;; One doppler process per CONFIG, not per secret. A user secrets.scm
;; resolves its whole key set from one config at load time, and the cache
;; starts empty on every boot, so ten names cost ten processes and about
;; four seconds of the daemon's start. `secrets download` returns the whole
;; config in one call for the same ~0.5s, so the first miss warms the rest.
;;
;; The trade: the cache then holds every secret in that config, not only the
;; names someone asked for. Nothing prints them. dp--secret-names still asks
;; --only-names, and doppler-secret-get still answers one name at a time.
(define *dp-config-warmed* '())

(define (dp--config-key project config)
  (string-append project "/" config))

(define (dp--warm-config! project config)
  (let ((ck (dp--config-key project config)))
    (unless (member ck *dp-config-warmed*)
      ;; mark first: a config that errors must not be retried per name
      (set! *dp-config-warmed* (cons ck *dp-config-warmed*))
      (let ((out (dp--run (string-append "secrets download --no-file --format json"
                                         " --project " (dp--quote project)
                                         " --config " (dp--quote config)))))
        (unless (dp--error? out)
          (let ((data (json-parse out)))
            (when (pair? data)
              (for-each
                (lambda (k)
                  (let ((key (dp--cache-key project config (symbol->string k))))
                    (unless (assoc key *dp-value-cache*)
                      (set! *dp-value-cache*
                        (cons (list key (plist-get data k)) *dp-value-cache*)))))
                (dp--plist-keys data)))))))))

(define (dp--fetch-one project config name)
  (let ((out (string-trim
               (dp--run (string-append "secrets get " (dp--quote name)
                                       " --project " (dp--quote project)
                                       " --config " (dp--quote config)
                                       " --plain")))))
    (if (or (equal? out "") (dp--error? out)) #f out)))

(define (doppler-secret-value project config name)
  (let ((key (dp--cache-key project config name)))
    (let ((hit (assoc key *dp-value-cache*)))
      (if hit
          (cadr hit)
          (begin
            (dp--warm-config! project config)
            (let ((hit (assoc key *dp-value-cache*)))
              (if hit
                  (cadr hit)
                  ;; the config gave no such name: ask for it alone, so a
                  ;; miss still caches and a later write still drops it
                  (let ((v (dp--fetch-one project config name)))
                    (set! *dp-value-cache* (cons (list key v) *dp-value-cache*))
                    v))))))))

;; the one hook keys.scm calls: (doppler-key-value VAR) -> value | #f
(define (doppler-key-value var)
  (doppler-secret-value key-doppler-project key-doppler-config var))

;; the same lookup for the model — separate from doppler-secret-names on
;; purpose, so a value only appears in the transcript when someone asks
;; for that exact name
(define (doppler-secret-get project config name)
  (or (doppler-secret-value project config name)
      (string-append "no such secret: " name)))

;; the raw CLI, for whatever the wrappers above don't cover — same
;; shell-out nm--run/notmuch use in notmuch.scm
(define (doppler args)
  (dp--run args))

;;; --- writes ------------------------------------------------------------------

(define (doppler-secret-set! project config name value)
  (let ((out
          (dp--run
            (string-append "secrets set " (dp--quote name) " " (dp--quote value)
                           " --project " (dp--quote project)
                           " --config " (dp--quote config)
                           " --silent --no-interactive"))))
    ;; --silent makes successful writes empty. Any text is an error or warning.
    (if (not (equal? (string-trim out) ""))
        (begin (message (string-trim out)) #f)
        (begin
          (dp--cache-drop! project config name)
          (when (boundp 'key-forget!) (key-forget! name))
          #t))))

(define (doppler-secret-delete! project config name)
  (let ((out
          (dp--run
            (string-append "secrets delete " (dp--quote name)
                           " --project " (dp--quote project)
                           " --config " (dp--quote config)
                           " --yes --silent"))))
    (if (not (equal? (string-trim out) ""))
        (begin (message (string-trim out)) #f)
        (begin
          (dp--cache-drop! project config name)
          (when (boundp 'key-forget!) (key-forget! name))
          #t))))

;;; --- list app ----------------------------------------------------------------

(define (doppler--project buf)
  (or (buffer-local buf 'doppler-project) key-doppler-project))

(define (doppler--config buf)
  (or (buffer-local buf 'doppler-config) key-doppler-config))

(define doppler--actions
  '(("doppler:project" "Project" "P")
    ("doppler:config" "Config" "C")
    ("doppler:add" "Add" "+")
    ("doppler:copy" "Copy" "RET")
    ("doppler:set" "Set" "e")
    ("doppler:mark" "Mark" "m")
    ("doppler:unmark" "Unmark" "u")
    ("doppler:all" "Mark all" "*")
    ("doppler:clear" "Clear marks" "U")
    ("doppler:flag" "Flag delete" "d")
    ("doppler:execute" "Execute" "x")
    ("doppler:filter" "Filter" "/")
    ("doppler:widen" "Widen" "\\")
    ("doppler:refresh" "Refresh" "g")))

(define (doppler--row-block name i)
  ;; Four table header lines put the first secret on line five.
  (component 'ui/row
    (list 'text name
          'class "doppler-row"
          'click (string-append "doppler:row:" (number->string i))
          'lines (list (+ i 5) (+ i 5))
          'mark "current")))

(define (doppler--render-blocks! buf names)
  (desktop-skip! buf 'render-blocks)
  (desktop-skip! buf 'doppler-total)
  (buffer-set-local! buf 'render-mode "blocks")
  (buffer-set-local! buf 'render-blocks
    (append
      (list
        (list 'tag "div" 'class "doppler-title"
              'text (string-append "Doppler  " (doppler--project buf)
                                   "/" (doppler--config buf)))
        (component 'ui/actions (list 'actions doppler--actions 'class "doppler-actions"))
        (component 'ui/section (list 'title "Secret names" 'count (length names))))
      (if (null? names)
          (list (component 'ui/empty (list 'text "No secrets in this project and config.")))
          (let loop ((xs names) (i 0) (rows '()))
            (if (null? xs)
                (reverse rows)
                (loop (cdr xs) (+ i 1)
                      (cons (doppler--row-block (car xs) i) rows))))))))

(define (doppler--rows buf)
  (let* ((names (dp--secret-name-list (doppler--project buf) (doppler--config buf)))
         (shown (list-keep buf names)))
    (buffer-set-local! buf 'doppler-total (length names))
    (doppler--render-blocks! buf shown)
    shown))

(define (doppler--project-candidates)
  (map (lambda (p)
         (list (custom--plist-get p 'name)
               (or (custom--plist-get p 'description) "")))
       (dp--projects-data)))

(define (doppler--config-candidates project)
  (map (lambda (c)
         (list (custom--plist-get c 'name)
               (or (custom--plist-get c 'environment) "")))
       (dp--configs-data project)))

(define (doppler--valid-name? name)
  (re-match? "^[A-Z_][A-Z0-9_]*$" name))

(define (doppler--set-value buf name value)
  (cond
    ((not (doppler--valid-name? name))
     (message "Use uppercase letters, numbers, and underscores in a secret name"))
    ((doppler-secret-set! (doppler--project buf) (doppler--config buf) name value)
     (list-refresh! buf)
     (message (string-append "Set " name)))))

(domain! 'secrets)
(effects! '(read external execute))

(define-command "doppler-refresh" "Read the secret names again"
  (lambda () (list-refresh! (current-buffer))))

(define-command "doppler-select-config" "Select the Doppler config to list"
  (lambda ()
    (let* ((buf (current-buffer))
           (project (doppler--project buf)))
      (minibuffer-read "Doppler config: " (doppler--config-candidates project)
        (lambda (config)
          (unless (equal? config "")
            (buffer-set-local! buf 'doppler-config config)
            (list-clear-marks! buf)
            (list-refresh! buf)
            (message (string-append project "/" config))))))))

(define-command "doppler-select-project" "Select the Doppler project and config to list"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Doppler project: " (doppler--project-candidates)
        (lambda (project)
          (unless (equal? project "")
            (buffer-set-local! buf 'doppler-project project)
            (let ((configs (doppler--config-candidates project)))
              (if (null? configs)
                  (begin
                    (buffer-set-local! buf 'doppler-config "")
                    (list-refresh! buf)
                    (message (string-append "No configs in " project)))
                  (minibuffer-read "Doppler config: " configs
                    (lambda (config)
                      (unless (equal? config "")
                        (buffer-set-local! buf 'doppler-config config)
                        (list-clear-marks! buf)
                        (list-refresh! buf)
                        (message (string-append project "/" config)))))))))))))

(domain! 'secrets)
(effects! '(write external execute))

(define-command "doppler-secret-add" "Add a secret to this Doppler config"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Secret name: " '()
        (lambda (input)
          (let ((name (string-upcase (string-trim input))))
            (if (not (doppler--valid-name? name))
                (message "Use uppercase letters, numbers, and underscores in a secret name")
                (minibuffer-read (string-append "Value for " name ": ") '()
                  (lambda (value) (doppler--set-value buf name value))))))))))

(define-command "doppler-secret-set" "Replace the value of the secret at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (name (list-current buf)))
      (if (not name)
          (message "No secret on this line")
          (minibuffer-read (string-append "New value for " name ": ") '()
            (lambda (value) (doppler--set-value buf name value)))))))

(define-command "doppler-secret-copy" "Copy the value of the secret at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (name (list-current buf)))
      (if (not name)
          (message "No secret on this line")
          (let ((value (doppler-secret-value
                         (doppler--project buf) (doppler--config buf) name)))
            (if value
                (begin
                  (clipboard-put! value)
                  (message (string-append "Copied " name)))
                (message (string-append "Cannot read " name))))))))

(define (doppler--click-command id)
  (cond ((equal? id "doppler:project") "doppler-select-project")
        ((equal? id "doppler:config") "doppler-select-config")
        ((equal? id "doppler:add") "doppler-secret-add")
        ((equal? id "doppler:copy") "doppler-secret-copy")
        ((equal? id "doppler:set") "doppler-secret-set")
        ((equal? id "doppler:mark") "list-mark")
        ((equal? id "doppler:unmark") "list-unmark")
        ((equal? id "doppler:all") "list-mark-all")
        ((equal? id "doppler:clear") "list-unmark-all")
        ((equal? id "doppler:flag") "list-flag-D")
        ((equal? id "doppler:execute") "list-execute")
        ((equal? id "doppler:filter") "list-filter")
        ((equal? id "doppler:widen") "list-filter-pop")
        ((equal? id "doppler:refresh") "doppler-refresh")
        (else #f)))

;; A row click selects it. The action bar runs the same commands as the keys.
(on-block-click! 'doppler
  (lambda (buf id)
    (and (equal? (buffer-local buf 'mode-name) "doppler-mode")
         (cond
           ((string-prefix? "doppler:row:" id)
            (let ((i (string->number
                       (substring-bytes id 12 (string-byte-length id)))))
              (when (number? i) (list-goto-index! buf i)))
            #t)
           ((doppler--click-command id)
            (run-command (doppler--click-command id))
            #t)
           (else #f)))))

(domain! 'secrets)
(effects! '(destroy external execute))

(define (doppler--delete-row buf name)
  (doppler-secret-delete!
    (doppler--project buf) (doppler--config buf) name))

(domain! 'secrets)
(effects! '(read external execute))

(mode-icon! "doppler-mode" "")

(define-list-mode! "doppler-mode"
  (list
    'doc (string-append
           "The secret names in one Doppler project and config. Values stay hidden. "
           "Click a row to select it, then use the action bar or the matching key. "
           "`RET` copies one value. `+` adds a secret, and `e` replaces one value. "
           "`P` selects a project, and `C` selects a config. `d` flags secrets, and "
           "`x` deletes them after confirmation.")
    'buffer *doppler-buffer*
    'rows doppler--rows
    'key (lambda (buf name) name)
    'columns (lambda (buf) (list (list "secret" #f)))
    'cells (lambda (buf name) (list name))
    'title (lambda (buf)
             (string-append "Doppler  " (doppler--project buf) "/" (doppler--config buf)))
    'meta (lambda (buf)
            (string-append (number->string (length (list-entries buf))) " secret names; values hidden"))
    'total (lambda (buf) (or (buffer-local buf 'doppler-total) 0))
    'footer (lambda (buf)
              '(("RET" "copy") ("+" "add") ("e" "set") ("P" "project")
                ("C" "config") ("d" "flag") ("x" "delete")
                ("/" "filter") ("g" "refresh") ("q" "quit")))
    'flags (list (list "d" "D" "delete" doppler--delete-row #t))
    'noun "secret"
    'keys '(("RET" "doppler-secret-copy") ("+" "doppler-secret-add")
            ("e" "doppler-secret-set") ("P" "doppler-select-project")
            ("C" "doppler-select-config") ("g" "doppler-refresh")
            ("q" "quit-window"))))

(define-command "doppler" "List and manage Doppler secret names"
  (lambda ()
    (buffer-create *doppler-buffer*)
    ;; Doppler is an app workspace, not a transient side surface.  Repair
    ;; desktop state from older versions that opened it through popper, and
    ;; give the buffer a stable group for the switcher and group commands.
    (buffer-set-local! *doppler-buffer* 'window-class #f)
    (buffer-set-local! *doppler-buffer* 'window-style #f)
    (buffer-set-local! *doppler-buffer* 'group *doppler-group*)
    (unless (buffer-local *doppler-buffer* 'doppler-project)
      (buffer-set-local! *doppler-buffer* 'doppler-project key-doppler-project))
    (unless (buffer-local *doppler-buffer* 'doppler-config)
      (buffer-set-local! *doppler-buffer* 'doppler-config key-doppler-config))
    (list-mode-show! "doppler-mode")))

(global-set-key "C-c a d" "doppler")

(define-style! 'doppler "
.doppler-title { font-family: var(--font-serif); font-size: 21px; padding: 6px 2px 10px; }
.doppler-row { border-bottom: 1px solid var(--border-bg); cursor: pointer; }
.doppler-row:hover { background: var(--hl-line-bg); }
")

(category! 'secrets)
(public! 'doppler-projects
  "(doppler-projects) — list Doppler project names (with descriptions)")
(public! 'doppler-configs
  "(doppler-configs PROJECT) — list config/environment names for a Doppler project")
(public! 'doppler-secret-names
  "(doppler-secret-names PROJECT CONFIG) — secret NAMES only in a project/config, never values — safe to print in chat")
(public! 'doppler-secret-get
  "(doppler-secret-get PROJECT CONFIG NAME) — the raw value of one named secret; only call this for a secret the user explicitly asked to see")
(public! 'doppler
  "(doppler ARGS) — the raw doppler CLI, ARGS is everything after `doppler` as one string, e.g. \"secrets --project foo --config prod --only-names\"")
