;;; permission-test.scm --- ONE policy, three modalities.
;;;
;;; The deny-list catches the irreversible outward acts. The chat mode
;;; decides the rest. A tool's declared effects decide before the mode
;;; does, and a per-agent profile can deny more.
;;;
;;; The lane tests stay in ExUnit. They run a whole agent turn against the
;;; Stub and ReqLLM backends and answer banners through keys.

(domain! 'testing)
(effects! '(write))

(define (t--perm-buf name) (test-buffer! name ""))

(deftest 'the-deny-list-catches-irreversible-outward-acts-and-only-those
  "a verb that cannot be undone from here asks; the rest do not"
  (lambda ()
    (for-each
      (lambda (verb)
        (check-true! (permission-denied-verb? verb)
                     (string-append "deny-listed: " verb)))
      '("send-mail" "sendmail" "mail-send" "Send Message to bob@example.com"
        "permanently delete" "empty-trash" "git push" "publish"))
    (for-each
      (lambda (safe)
        (check-false! (permission-denied-verb? safe)
                      (string-append "passes: " safe)))
      '("buffer-text" "read foo.ex" "eval-scheme" "mail-search tag:inbox"))))

(deftest 'mode-decides-everything-the-deny-list-does-not
  "approve, ask and auto, at our own chokepoints"
  (lambda ()
    (let ((buf (t--perm-buf "*zz-policy*")))
      ;; default (approve): ordinary tools run, deny-listed ones ask
      (check-equal! (*permission-policy* buf "eval-scheme" "tool" "(+ 1 1)")
                    'allow-always "approve runs an ordinary tool")
      (check-equal! (*permission-policy* buf "eval-scheme" "tool" "(mail-send ...)")
                    'ask "approve still asks for the deny-list")

      ;; ask mode: everything asks
      (buffer-set-local! buf 'chat-permission-mode 'ask)
      (check-equal! (*permission-policy* buf "eval-scheme" "tool" "(+ 1 1)")
                    'ask "ask asks for everything")

      ;; auto: same as approve at OUR chokepoints — the deny-list holds
      (buffer-set-local! buf 'chat-permission-mode 'auto)
      (check-equal! (*permission-policy* buf "eval-scheme" "tool" "(+ 1 1)")
                    'allow-always "auto runs an ordinary tool")
      (check-equal! (*permission-policy* buf "eval-scheme" "tool" "(mail-send ...)")
                    'ask "auto still asks for the deny-list")
      (buffer-kill! buf))))

(deftest 'a-tools-declared-side-effects-decide-before-the-chat-mode-does
  "the effects are the tool's own claim, and they outrank the mode"
  (lambda ()
    (let ((buf (t--perm-buf "*zz-effects*")))
      (define-tool! 'zz-shred "test: irreversible" '()
        (lambda (args) "gone") '(destroy))

      ;; read-only tools never ask, even in ask mode
      (buffer-set-local! buf 'chat-permission-mode 'ask)
      (check-equal! (*permission-policy* buf "describe-function" "tool" "describe args")
                    'allow-always "a read never asks")

      ;; Discovery is load-bearing. Its small embedding call must not block
      ;; an agent before the agent can find the editor API.
      (check-equal! (*permission-policy* buf "apropos" "tool" "apropos args")
                    'allow-always "semantic discovery never asks")

      ;; destroy-effect tools ask, even in approve mode
      (buffer-set-local! buf 'chat-permission-mode 'approve)
      (check-equal! (*permission-policy* buf "zz-shred" "tool" "zz-shred args")
                    'ask "a destroy always asks")

      ;; a tool the catalog does not know falls through to the mode
      (check-equal! (*permission-policy* buf "zz-unknown" "tool" "zz-unknown args")
                    'allow-always "an unknown tool follows the mode")

      (set! *llm-tools* (remove (lambda (t) (equal? (car t) 'zz-shred)) *llm-tools*))
      (buffer-kill! buf))))

(deftest 'a-per-agent-profile-denies-its-own-patterns
  "no profile is allow-all; a profile adds to the shared deny-list"
  (lambda ()
    (let ((buf (t--perm-buf "*zz-profile*")))
      ;; no profile: the shared deny-list holds, everything else allows
      (check-equal! (*permission-policy* buf "eval-scheme" "tool" "(graphql-run ...)")
                    'allow-always "no profile allows")

      ;; a profile with one extra deny pattern rejects exactly that verb
      (buffer-set-local! buf 'agent-permission-profile '(deny-patterns ("graphql")))
      (check-equal! (*permission-policy* buf "eval-scheme" "tool" "(graphql-run ...)")
                    'reject "the profile pattern rejects")
      (check-equal! (*permission-policy* buf "eval-scheme" "tool" "(+ 1 1)")
                    'allow-always "and leaves the rest alone")

      ;; the pure seam permission packages call
      (check-false! (profile-denies? #f "anything") "no profile is allow-all")
      (check-true! (profile-denies? '(deny-patterns ("git push")) "git push origin")
                   "a pattern matches its verb")
      (buffer-kill! buf))))

(deftest 'modes-can-grant-a-named-command-through-the-shared-policy
  "the grant names the command and the buffer it holds in"
  (lambda ()
    (let ((allowed (t--perm-buf "*zz-command-allowed*"))
          (other (t--perm-buf "*zz-command-other*")))
      (allow-command-when! "zz-reload" (lambda (buf) (equal? buf allowed)))
      (check-equal! (*permission-policy* allowed "zz-reload" "command" "")
                    'allow-always "the granted buffer runs it")
      (check-equal! (*permission-policy* other "zz-reload" "command" "")
                    'ask "every other buffer asks")

      (set! *command-permission-rules*
        (remove (lambda (r) (equal? (car r) "zz-reload")) *command-permission-rules*))
      (buffer-kill! allowed)
      (buffer-kill! other))))

(deftest 'the-mcp-proxy-refuses-deny-listed-payloads
  "the gate holds even when the agent stopped asking"
  (lambda ()
    (let* ((args (base64-encode (json-encode (list 'code "(mail-send \"bob\" \"hi\")"))))
           (out (base64-decode (mcp-proxy-call "eval-scheme" args))))
      (check-contains! out "refused" "the call is refused")
      ;; the pattern that caught it, so the agent knows what to ask for
      (check-contains! out "mail" "and it names the pattern"))

    (let* ((ok (base64-encode (json-encode (list 'code "(+ 20 22)"))))
           (out (base64-decode (mcp-proxy-call "eval-scheme" ok))))
      (check-contains! out "42" "an ordinary payload still runs"))))
