;;; keys-test.scm --- the secret provider is the chain's third step.

(define (t--keys-with-provider provider thunk)
  (let ((before secret-provider))
    (customize-set! 'secret-provider provider)
    (key-forget-all!)
    (let ((out (thunk)))
      (customize-set! 'secret-provider before)
      (key-forget-all!)
      out)))

(deftest 'the-secret-provider-answers-after-the-environment-and-the-files
  "a name the environment and the key files do not hold reaches the provider"
  (lambda ()
    (t--keys-with-provider
      (lambda (name) (if (equal? name "ZZ_KEYS_PROVIDED") "from-provider" #f))
      (lambda ()
        (check-equal! (key-get "ZZ_KEYS_PROVIDED") "from-provider" "the provider answers")
        (check-false! (key-get "ZZ_KEYS_NOT_PROVIDED") "a name it does not hold is #f")))))

(deftest 'no-secret-provider-ends-the-chain
  "with the custom at #f, an unknown name is #f and nothing raises"
  (lambda ()
    (t--keys-with-provider #f
      (lambda ()
        (check-false! (key-get "ZZ_KEYS_NOBODY") "the chain ends at the files")))))

(deftest 'the-provider-is-asked-once-per-name
  "key-get caches the provider's answer, misses included"
  (lambda ()
    (let ((asked 0))
      (t--keys-with-provider
        (lambda (name) (set! asked (+ asked 1)) #f)
        (lambda ()
          (key-get "ZZ_KEYS_ONCE")
          (key-get "ZZ_KEYS_ONCE")
          (check-equal! asked 1 "one ask for two lookups"))))))

(deftest 'a-secret-argument-is-one-shell-word
  "a quote inside a lookup argument stays inside its shell word"
  (lambda ()
    (check-equal! (secret--shell-word "it's") "'it'\\''s'" "the quote")
    (check-equal! (secret-command (string-append "printf %s " (secret--shell-word "a b'c")))
                  "a b'c" "the shell reads it back whole")))

(deftest 'a-secret-command-answers-its-output-or-false
  "secret-command trims the output, and an empty output is #f"
  (lambda ()
    (check-equal! (secret-command "echo '  k-123  '") "k-123" "trimmed")
    (check-false! (secret-command "true") "no output")))
