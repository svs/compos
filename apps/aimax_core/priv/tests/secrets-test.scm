;;; secrets-test.scm --- one resolution point, every module.
;;;
;;; A "@VAR" value in config is a reference, resolved once in Scheme at
;;; the moment a spec leaves for Elixir. These hold the shape of
;;; spec-resolve, which every module that carries a secret now shares.
;;;
;;; The key cache is seeded directly so no test reads the real chain: a
;;; test that shells out to Doppler is slow and fails without it.

(define (t--seed-keys!)
  (set! *key-cache*
    (append (list (list "T_TOKEN" "s3cret") (list "T_ABSENT" #f)) *key-cache*)))

(deftest 'spec-resolve-reads-the-three-shapes-a-secret-arrives-in
  "value, plist, and each name how a field carries its reference"
  (lambda ()
    (t--seed-keys!)
    (let ((out (spec-resolve
                 '(url "@T_TOKEN"
                   env (A "@T_TOKEN" B "plain")
                   args ("--k" "@T_TOKEN")
                   other "@T_TOKEN")
                 '(url value env plist args each))))
      (check-equal! (plist-get out 'url) "s3cret" "a value field resolved")
      (check-equal! (plist-get (plist-get out 'env) 'A) "s3cret" "an env reference resolved")
      (check-equal! (plist-get (plist-get out 'env) 'B) "plain" "a plain env value survives")
      (check-equal! (cadr (plist-get out 'args)) "s3cret" "an arg reference resolved")
      (check-equal! (car (plist-get out 'args)) "--k" "a plain arg survives")
      (check-equal! (plist-get out 'other) "@T_TOKEN" "an undeclared field is untouched"))))

(deftest 'a-reference-nobody-can-answer-becomes-empty-not-the-literal
  "a header holding the text @VAR reads worse than an empty one"
  (lambda ()
    (t--seed-keys!)
    (check-equal! (plist-get (spec-resolve '(url "@T_ABSENT") '(url value)) 'url)
                  "" "an unanswered reference is empty")))

(deftest 'each-resolves-arguments-one-by-one-rather-than-joining-them
  "joining would build one argument out of several"
  (lambda ()
    (t--seed-keys!)
    (let ((out (spec-resolve '(args ("--token" "@T_TOKEN" "--flag")) '(args each))))
      (check-equal! (length (plist-get out 'args)) 3 "three arguments stay three")
      (check-equal! (nth 1 (plist-get out 'args)) "s3cret" "the middle one resolved"))))

(deftest 'a-value-field-joins-its-parts
  "a value only part of which is secret stays a reference in config"
  (lambda ()
    (t--seed-keys!)
    (check-equal!
      (plist-get (spec-resolve '(url ("https://x/?k=" "@T_TOKEN")) '(url value)) 'url)
      "https://x/?k=s3cret" "the parts joined around the secret")))

(deftest 'resolving-twice-does-not-re-read-a-secret-that-starts-with-an-at
  "a resolved spec is data, not config; running it through again is a bug"
  (lambda ()
    (set! *key-cache* (cons (list "T_AT" "@T_TOKEN") *key-cache*))
    (t--seed-keys!)
    (let* ((once (spec-resolve '(url "@T_AT") '(url value)))
           (twice (spec-resolve once '(url value))))
      (check-equal! (plist-get once 'url) "@T_TOKEN" "the secret's own text survives")
      (check-equal! (plist-get twice 'url) "s3cret"
        "resolving again would read it as a reference, which is why nobody does"))))

;;; --- the modules that share it -----------------------------------------------

(deftest 'every-module-that-carries-a-secret-declares-its-fields
  "one resolution point, and each module says which fields reach it"
  (lambda ()
    (t--seed-keys!)

    ;; a database password must resolve; the adapter name must not
    (let ((out (db-resolve-spec '(adapter "postgres" password "@T_TOKEN" database "app"))))
      (check-equal! (plist-get out 'password) "s3cret" "the password resolved")
      (check-equal! (plist-get out 'adapter) "postgres" "the adapter is not a secret")
      (check-equal! (plist-get out 'database) "app" "a plain value survives"))

    ;; an endpoint subprocess environment is the same shape MCP uses
    (let ((out (endpoint-resolve-spec
                 '(command "psql" env (PGPASSWORD "@T_TOKEN") framing "line"))))
      (check-equal! (plist-get (plist-get out 'env) 'PGPASSWORD) "s3cret" "the env resolved")
      (check-equal! (plist-get out 'framing) "line" "the framing is not a secret"))

    ;; mcp keeps the behaviour it had before it shared the function
    (let ((out (mcp-resolve-spec
                 '(url "@T_TOKEN" headers (Authorization "@T_TOKEN") command "x"))))
      (check-equal! (plist-get out 'url) "s3cret" "the url resolved")
      (check-equal! (plist-get (plist-get out 'headers) 'Authorization) "s3cret" "the header resolved")
      (check-equal! (plist-get out 'command) "x" "the command is untouched"))))

(deftest 'the-registry-keeps-the-reference-not-the-secret
  "config holds @VAR; only the spec on its way to Elixir holds the value"
  (lambda ()
    (t--seed-keys!)
    (db-register! "t-secret-db" '(adapter "postgres" password "@T_TOKEN"))
    (check-equal! (plist-get (db-spec "t-secret-db") 'password) "@T_TOKEN"
      "the stored spec still holds the reference")
    (check-equal! (plist-get (db-resolve-spec (db-spec "t-secret-db")) 'password) "s3cret"
      "only the resolved copy holds the secret")))
