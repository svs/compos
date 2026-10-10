;;; keys.scm --- the one key chain, userland Scheme.
;;;
;;; Where a secret comes from is policy, so it lives here. No Elixir
;;; module knows about Doppler, about ~/.compos/<name>-key, or about the
;;; order of the three. Elixir asks for a key by name and gets a string.
;;;
;;; The chain, first hit wins:
;;;   1. the environment                (getenv VAR)
;;;   2. ~/.compos/<name>-key            (VAR minus _API_KEY, downcased)
;;;   3. the secret provider            (the `secret-provider` custom)
;;;
;;; The provider is one function from a name to a value or #f, and the
;;; user config supplies it. Core names no provider:
;;;
;;;   (customize-set! 'secret-provider doppler-key-value)
;;;   (customize-set! 'secret-provider
;;;     (lambda (name) (shell-command->string (string-append "pass show " name))))
;;;
;;; A "@VAR" value anywhere in config is a reference, not a key: MCP
;;; specs and ACP env pairs carry "@EXA_API_KEY" and key-resolve turns
;;; that into the value at the moment the spec leaves for Elixir. Config
;;; files stay secret-free.
;;;
;;; key-get caches, misses included: a missing key costs one doppler
;;; process for the whole session, not one per request. Change a secret
;;; in Doppler and the editor keeps the old value until key-forget!.

(defgroup 'keys "Secrets: the key chain (environment, files, Doppler).")

;;; --- the sources --------------------------------------------------------------

(define *key-cache* '())

;; GOOGLE_API_KEY -> ~/.compos/google-key, MXROUTE_PASSWORD -> ~/.compos/mxroute_password-key
(define (key--file-name var)
  (string-downcase (string-join (string-split var "_API_KEY") "")))

(define (key--non-empty s)
  (if (or (not s) (equal? s "")) #f s))

(define (key--from-file var)
  (let ((path (string-append (compos-config-dir) "/" (key--file-name var) "-key")))
    (if (file-exists? path)
        (key--non-empty (string-trim (or (read-file path) "")))
        #f)))

;; the seam: one function from a name to a value or #f, set by user config
(defcustom 'secret-provider #f
  "A function from a secret name to its value or #f, asked after the environment and the key files. User config sets it; #f ends the chain."
  'group 'keys)

(define (key--from-provider var)
  (if (procedure? secret-provider)
      (secret-provider var)
      #f))

;;; --- the chain ----------------------------------------------------------------

;; the value of VAR, or #f. Cached under VAR, misses too.
(define (key-get var)
  (let ((hit (assoc var *key-cache*)))
    (if hit
        (cadr hit)
        (let ((v (or (getenv var)
                     (key--from-file var)
                     (key--from-provider var)
                     #f)))
          (set! *key-cache* (cons (list var v) *key-cache*))
          v))))

;; Explicit provider -> key VALUE, set by user config (ai-config.scm). This
;; is the whole mapping: there is no provider -> secret-name convention, so a
;; provider with an odd secret name (GEMINI_API_KEY_EMACS) is a config line,
;; never a guess. Mirrors secrets.el: load into a global, register the
;; mapping, and the value — never the secret name — is what travels.
(define *llm-keys* '()) ; (("deepseek" "sk-...") ...)

(define (register-llm-key! provider value)
  (let ((p (if (symbol? provider) (symbol->string provider) provider)))
    ;; a key that resolved to nothing is a boot-time failure the user
    ;; otherwise meets as "no api key" at send time — say it now
    (when (or (equal? value #f) (equal? value ""))
      (message (string-append "llm key for " p
                              " resolved empty — check the secret provider, then M-x reload-file on ai-config.scm")))
    (set! *llm-keys* (alist-put *llm-keys* p value))
    value))

;; A provider id -> the resolved key VALUE, or #f when unregistered. Elixir
;; asks this by provider and passes the value on.
(define (llm-key provider)
  (let ((e (assoc provider *llm-keys*)))
    (if e (cadr e) #f)))

;; Explicit provider -> the address its requests go to, when that is not the
;; provider's own cloud. A self-hosted OpenAI-compatible server is the same
;; provider SHAPE at a different address (mlx_lm.server, vLLM, ollama), so the
;; address is config beside the key rather than a second mechanism. Elixir asks
;; for it by provider exactly as it asks for the key, and #f leaves req_llm's
;; own default in place. Compile-time Elixir config would answer too; a port
;; that needs a daemon restart to change is why this lives here instead.
(define *llm-base-urls* '()) ; (("vllm" "http://127.0.0.1:8127/v1") ...)

(define (register-llm-base-url! provider value)
  (let ((p (if (symbol? provider) (symbol->string provider) provider)))
    (set! *llm-base-urls* (alist-put *llm-base-urls* p value))
    value))

(define (llm-base-url provider)
  (let ((e (assoc provider *llm-base-urls*)))
    (if e (cadr e) #f)))

;; drop VAR from the cache, so the next key-get walks the chain again
(define (key-forget! var)
  (set! *key-cache*
    (remove (lambda (e) (equal? (car e) var)) *key-cache*))
  var)

(define (key-forget-all!)
  (set! *key-cache* '())
  #t)

;; the names the chain answered for, so a human can see what is cached
;; without seeing any value
(define (key-cached-names)
  (map car *key-cache*))

;;; --- references ---------------------------------------------------------------

;; "@EXA_API_KEY" -> the key; anything else passes through. A reference
;; that resolves to nothing becomes "" — the server then says "invalid
;; key", which reads better than a header holding the literal "@VAR".
;;
;; A list of parts joins after each part resolves, so a value that only
;; PART of which is the secret stays a reference in config:
;;   'Authorization (list "Bearer " "@ATS_ASH_TOKEN")
;; Doppler then holds the token alone, not the word Bearer as well.
(define (key-resolve v)
  (cond ((pair? v)
         (fold (lambda (acc part) (string-append acc (key-resolve part))) "" v))
        ((and (string? v) (string-prefix? "@" v))
         (or (key-get (substring v 1 (string-length v))) ""))
        (else v)))

;; every value of a plist, keys untouched: (K "@VAR" K2 "plain") shapes
;; both MCP env and MCP headers
(define (key-resolve-plist pl)
  (if (or (null? pl) (null? (cdr pl)))
      '()
      (cons (car pl)
            (cons (key-resolve (cadr pl))
                  (key-resolve-plist (cddr pl))))))


;; One spec, one resolution point, every module.
;;
;; FIELDS is a plist naming the spec keys that may hold a reference, and
;; how each one carries it:
;;
;;   value  the value is a reference, or a list of parts to join
;;   plist  the value is a plist of its own; every value resolves (env)
;;   each   the value is a list; every element resolves on its own (args)
;;
;; A key that FIELDS does not name passes through untouched, so a spec
;; never resolves twice and a value whose own text starts with "@" stays
;; literal. Resolve once, in Scheme, at the moment the spec leaves for
;; Elixir: no Elixir module holds a secret or knows where one lives.
;;
;;   (spec-resolve spec '(url value env plist args each))
(define (spec-resolve spec fields)
  (if (or (null? spec) (null? (cdr spec)))
      '()
      (let* ((k (car spec))
             (v (cadr spec))
             (kind (plist-get fields k)))
        (cons k
              (cons (cond ((equal? kind 'plist) (key-resolve-plist v))
                          ((equal? kind 'each) (map key-resolve v))
                          ((equal? kind 'value) (key-resolve v))
                          (else v))
                    (spec-resolve (cddr spec) fields))))))

;;; --- secret backends ----------------------------------------------------------
;;; One function per secret tool. Each answers the secret as a string, or #f.
;;; secrets.scm names a key by one of these calls, so the value stays in the
;;; tool and every boot reads the current one.

(domain! 'secrets)
(effects! '(read external execute))

;; TEXT as one shell word: inside single quotes, with each quote closed,
;; escaped, and opened again.
(define (secret--shell-word text)
  (string-append "'" (string-join (string-split text "'") "'\\''") "'"))

;; The output of CMD trimmed, or #f when it printed nothing.
(define (secret-command cmd)
  (let ((out (string-trim (shell-command->string (string-append cmd " 2>/dev/null")))))
    (if (equal? out "") #f out)))

;; 1Password: REF is a secret reference, op://VAULT/ITEM/FIELD.
(define (op-secret-get ref)
  (secret-command (string-append "op read " (secret--shell-word ref))))

;; The macOS Keychain: a generic password by its service, and by account
;; when one is given.
(define (keychain-secret-get service &optional account)
  (secret-command
    (string-append "security find-generic-password -w -s " (secret--shell-word service)
                   (if (and account (not (equal? account "")))
                       (string-append " -a " (secret--shell-word account))
                       ""))))

;; The Linux Secret Service: the secret stored with the attribute
;; service=SERVICE (secret-tool store --label=... service SERVICE).
(define (secret-tool-get service)
  (secret-command (string-append "secret-tool lookup service " (secret--shell-word service))))

(category! 'secrets)
(public! 'spec-resolve
  "(spec-resolve SPEC FIELDS) — resolve the \"@VAR\" references in a config spec; FIELDS names each secret-bearing key as 'value, 'plist, or 'each")
(public! 'key-resolve
  "(key-resolve V) — \"@VAR\" becomes the secret; a list of parts joins after each resolves; anything else passes through")
(public! 'key-resolve-plist
  "(key-resolve-plist PL) — resolve every value of a plist, keys untouched")
(public! 'key-forget!
  "(key-forget! VAR) — drop VAR from the key cache; the next lookup reads Doppler again")
(public! 'key-cached-names
  "(key-cached-names) — the variable names the key chain answered for this session, values never")
(public! 'llm-key
  "(llm-key PROVIDER) — the resolved key VALUE for a provider id, or #f when unregistered; pass this to the LLM config")
(public! 'register-llm-key!
  "(register-llm-key! PROVIDER VALUE) — set the explicit key VALUE for a provider")
(public! 'llm-base-url
  "(llm-base-url PROVIDER) — the address a provider's requests go to, or #f for the provider's own")
(public! 'register-llm-base-url!
  "(register-llm-base-url! PROVIDER VALUE) — send a provider's requests to a self-hosted OpenAI-compatible server")
(public! 'secret-command
  "(secret-command CMD) — the trimmed output of the shell command CMD, or #f; a key from any tool")
(public! 'op-secret-get
  "(op-secret-get \"op://VAULT/ITEM/FIELD\") — a 1Password secret, through op read")
(public! 'keychain-secret-get
  "(keychain-secret-get SERVICE [ACCOUNT]) — a macOS Keychain generic password")
(public! 'secret-tool-get
  "(secret-tool-get SERVICE) — a Linux Secret Service secret stored with service=SERVICE")
