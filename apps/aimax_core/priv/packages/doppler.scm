;;; doppler.scm --- secrets lookup over the doppler CLI, userland Scheme.
;;;
;;; No Elixir knows what Doppler is. Same shape as notmuch.scm: shell out
;;; to the `doppler` CLI (already authenticated via `doppler login` on
;;; this machine) and parse --json output. No UI here, just tools for the
;;; model/chat to look things up directly instead of clicking through the
;;; web dashboard.
;;;
;;; Secret VALUES are sensitive and land in the chat transcript once
;;; printed — dp--secret-names never asks the CLI for values at all
;;; (--only-names), and dp-secret-get is a separate, explicit call so a
;;; value only ever shows up when someone asks for that exact secret.

(defgroup 'doppler "Secrets: doppler CLI lookups (projects, configs, secrets).")

(defcustom 'doppler-program "doppler"
  "The doppler executable." 'group 'doppler)

;; The key chain's Doppler source: which project/config the chain reads.
;; keys.scm asks for a key by name and never knows Doppler is behind it.
(defcustom 'key-doppler-project "personal"
  "The Doppler project the key chain reads." 'group 'doppler)

(defcustom 'key-doppler-config "dev"
  "The Doppler config the key chain reads." 'group 'doppler)

;;; --- CLI plumbing -------------------------------------------------------------

(define (dp--quote s)
  (string-append "'" (string-join (string-split s "'") "'\\''") "'"))

(define (dp--run args)
  (shell-command->string (string-append doppler-program " " args)))

(define (dp--json args)
  (json-parse (dp--run (string-append args " --json"))))

;;; --- lookups for the model ----------------------------------------------------

(define (doppler-projects)
  (let ((ps (or (dp--json "projects") '())))
    (if (null? ps)
        "no projects"
        (fold (lambda (acc p)
                (string-append acc (custom--plist-get p 'name)
                  (let ((d (custom--plist-get p 'description)))
                    (if (and d (not (equal? d ""))) (string-append " — " d) ""))
                  "\n"))
              "" ps))))

(define (doppler-configs project)
  (let ((cs (or (dp--json (string-append "configs --project " (dp--quote project))) '())))
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
  (let ((names (dp--plist-keys
                 (or (dp--json (string-append "secrets --project " (dp--quote project)
                                              " --config " (dp--quote config)
                                              " --only-names"))
                     '()))))
    (if (null? names)
        (string-append "no secrets (or no such project/config: " project "/" config ")")
        (string-join (map symbol->string names) "\n"))))

;; the one call that returns an actual secret value, or #f when the
;; project, the config, or the name does not exist. The CLI writes its
;; errors to stderr and dp--run folds those in, so a failure arrives as
;; text and not as a status — read it back out. packages/keys.scm calls
;; this as the last link of the key chain.
(define (doppler-secret-value project config name)
  (let ((out (string-trim
               (dp--run (string-append "secrets get " (dp--quote name)
                                       " --project " (dp--quote project)
                                       " --config " (dp--quote config)
                                       " --plain")))))
    (if (or (equal? out "") (string-contains? out "Doppler Error"))
        #f
        out)))

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
