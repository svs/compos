;;; keys.scm --- the one key chain, userland Scheme.
;;;
;;; Where a secret comes from is policy, so it lives here. No Elixir
;;; module knows about Doppler, about ~/.aimax/<name>-key, or about the
;;; order of the three. Elixir asks for a key by name and gets a string.
;;;
;;; The chain, first hit wins:
;;;   1. the environment                (getenv VAR)
;;;   2. ~/.aimax/<name>-key            (VAR minus _API_KEY, downcased)
;;;   3. Doppler                        (packages/doppler.scm)
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

;; GOOGLE_API_KEY -> ~/.aimax/google-key, MXROUTE_PASSWORD -> ~/.aimax/mxroute_password-key
(define (key--file-name var)
  (string-downcase (string-join (string-split var "_API_KEY") "")))

(define (key--non-empty s)
  (if (or (not s) (equal? s "")) #f s))

(define (key--from-file var)
  (let ((path (string-append (aimax-config-dir) "/" (key--file-name var) "-key")))
    (if (file-exists? path)
        (key--non-empty (string-trim (or (read-file path) "")))
        #f)))

;; doppler.scm supplies (doppler-key-value VAR) when it loads; the chain
;; consults it only when bound, so a missing doppler package never breaks
;; key lookup. Its project/config live there, not here.
(define (key--from-doppler var)
  (if (boundp 'doppler-key-value)
      (doppler-key-value var)
      #f))

;;; --- the chain ----------------------------------------------------------------

;; the value of VAR, or #f. Cached under VAR, misses too.
(define (key-get var)
  (let ((hit (assoc var *key-cache*)))
    (if hit
        (cadr hit)
        (let ((v (or (getenv var)
                     (key--from-file var)
                     (key--from-doppler var)
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
                              " resolved empty — check doppler, then M-x reload-file on ai-config.scm")))
    (set! *llm-keys*
      (cons (list p value)
            (remove (lambda (e) (equal? (car e) p)) *llm-keys*)))
    value))

;; A provider id -> the resolved key VALUE, or #f when unregistered. Elixir
;; asks this by provider and passes the value on.
(define (llm-key provider)
  (let ((e (assoc provider *llm-keys*)))
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

(category! 'secrets)
(public! 'key-forget!
  "(key-forget! VAR) — drop VAR from the key cache; the next lookup reads Doppler again")
(public! 'key-cached-names
  "(key-cached-names) — the variable names the key chain answered for this session, values never")
(public! 'llm-key
  "(llm-key PROVIDER) — the resolved key VALUE for a provider id, or #f when unregistered; pass this to the LLM config")
(public! 'register-llm-key!
  "(register-llm-key! PROVIDER VALUE) — set the explicit key VALUE for a provider")
