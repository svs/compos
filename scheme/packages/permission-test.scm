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
      ;; default (auto): ordinary tools run, deny-listed ones ask
      (check-equal! (permit? buf "eval-scheme" "tool" "(+ 1 1)")
                    'allow-always "the default runs an ordinary tool")
      (check-equal! (permit? buf "eval-scheme" "tool" "(shell-command->string \"sendmail bob\" d)")
                    'ask "the default still asks for the deny-list")

      ;; approve: a shell command is the one thing it stops for
      (buffer-set-local! buf 'chat-permission-mode 'approve)
      (check-equal! (permit? buf "Bash" "execute" "{}")
                    'ask "approve asks before a shell command")

      ;; ask mode: everything asks
      (buffer-set-local! buf 'chat-permission-mode 'ask)
      (check-equal! (permit? buf "eval-scheme" "tool" "(+ 1 1)")
                    'ask "ask asks for everything")

      ;; auto: same as approve at OUR chokepoints — the deny-list holds
      (buffer-set-local! buf 'chat-permission-mode 'auto)
      (check-equal! (permit? buf "eval-scheme" "tool" "(+ 1 1)")
                    'allow-always "auto runs an ordinary tool")
      (check-equal! (permit? buf "eval-scheme" "tool" "(shell-command->string \"sendmail bob\" d)")
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
      (check-equal! (permit? buf "describe-function" "tool" "describe args")
                    'allow-always "a read never asks")

      ;; Discovery is load-bearing. Its small embedding call must not block
      ;; an agent before the agent can find the editor API.
      (check-equal! (permit? buf "apropos" "tool" "apropos args")
                    'allow-always "semantic discovery never asks")

      ;; destroy-effect tools ask, even in approve mode
      (buffer-set-local! buf 'chat-permission-mode 'approve)
      (check-equal! (permit? buf "zz-shred" "tool" "zz-shred args")
                    'ask "a destroy always asks")

      ;; a tool the catalog does not know falls through to the mode
      (check-equal! (permit? buf "zz-unknown" "tool" "zz-unknown args")
                    'allow-always "an unknown tool follows the mode")

      (set! *llm-tools* (remove (lambda (t) (equal? (car t) 'zz-shred)) *llm-tools*))
      (buffer-kill! buf))))

(deftest 'a-per-agent-profile-denies-its-own-patterns
  "no profile is allow-all; a profile adds to the shared deny-list"
  (lambda ()
    (let ((buf (t--perm-buf "*zz-profile*")))
      ;; no profile: the shared deny-list holds, everything else allows
      (check-equal! (permit? buf "eval-scheme" "tool" "(graphql-run ...)")
                    'allow-always "no profile allows")

      ;; a profile with one extra deny pattern rejects exactly that verb
      (buffer-set-local! buf 'agent-permission-profile '(deny-patterns ("graphql")))
      (check-equal! (permit? buf "eval-scheme" "tool" "(graphql-run ...)")
                    'reject "the profile pattern rejects")
      (check-equal! (permit? buf "eval-scheme" "tool" "(+ 1 1)")
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
      (check-equal! (permit? allowed "zz-reload" "command" "")
                    'allow-always "the granted buffer runs it")
      (check-equal! (permit? other "zz-reload" "command" "")
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

(deftest 'the-agent-writes-buffers-so-the-filesystem-verbs-are-refused
  "a write that never touches a buffer has no provenance and leaves a stale one"
  (lambda ()
    (let ((buf (t--perm-buf "*zz-fs-policy*")))
      ;; ACP labels what a call does to the workspace, whatever it is called
      (for-each
        (lambda (kind)
          (check-equal! (permit? buf "some tool" kind "{}")
                        'reject (string-append "refused by kind: " kind)))
        '("edit" "delete" "move"))

      ;; a lane that sends no kind is caught by the tool's own name
      (for-each
        (lambda (title)
          (check-equal! (permit? buf title "" "{}")
                        'reject (string-append "refused by name: " title)))
        '("Edit" "Write" "MultiEdit" "NotebookEdit"
          "apply_patch" "str_replace_editor" "fs/write_text_file"))

      ;; reading a file is not writing one, and compos's own tools arrive
      ;; as "other", so eval-scheme and the code editors keep working
      (check-equal! (permit? buf "Read apps/x.scm" "read" "{}")
                    'allow-always "reading a file is still allowed")
      (check-equal! (permit? buf
                      "compos:eval-scheme: (code-replace! ...)" "other" "{}")
                    'allow-always "the editor's own tools keep working")

      ;; the setting is the whole escape hatch
      (let ((was agent-filesystem-tools))
        (set! agent-filesystem-tools "ask")
        (check-equal! (permit? buf "Write" "edit" "{}") 'ask
                      "ask puts the write in front of the user")
        (set! agent-filesystem-tools "allow")
        (check-equal! (permit? buf "Write" "edit" "{}") 'allow-always
                      "allow hands the filesystem back")
        (set! agent-filesystem-tools was))
      (buffer-kill! buf))))

(deftest 'git-that-overwrites-the-work-tree-asks-first
  "Reading, staging and committing pass. A verb that lands text the editor
   never saw stops for the user, because it can lose an unsaved buffer."
  (lambda ()
    (let* ((buf (t--perm-buf "*zz-git-policy*"))
           (g (lambda (verb)
                (string-append "(shell-command->string \"git " verb "\" d)"))))
      (for-each
        (lambda (verb)
          (check-equal! (permit? buf "eval-scheme" "tool" (g verb))
                        'allow-always (string-append "git " verb " writes no working file")))
        '("status --porcelain" "log --oneline -5" "diff HEAD"
          "add -A" "commit -m x" "branch -a" "reset HEAD file"))

      (for-each
        (lambda (verb)
          (check-equal! (permit? buf "eval-scheme" "tool" (g verb))
                        'ask (string-append "git " verb " rewrites the work tree")))
        '("checkout -- ." "restore src" "stash" "clean -fd"
          "apply patch.diff" "pull --rebase" "merge main" "rebase main"
          "revert HEAD" "reset --hard HEAD" "reset --merge"))

      ;; the read side of git in Scheme is untouched
      (check-equal! (permit? buf "eval-scheme" "tool" "(git-diff d)")
                    'allow-always "the catalog's own git readers stay open")
      (buffer-kill! buf))))

(deftest 'an-always-answer-becomes-a-rule-the-chat-keeps
  "The backend's own allow_always binds the backend. This policy runs
   first, so the answer has to live here or the next call asks again."
  (lambda ()
    (let ((buf (t--perm-buf "*zz-always*"))
          (raw "{\"kind\":\"execute\",\"rawInput\":{\"command\":\"gh api repos/a\"}}"))
      ;; the verb is the key: a command's arguments differ every time
      (check-equal! (permission-signature "Run command" "execute" raw) "gh api"
                    "an execute rule is keyed by the command's verb")
      (check-equal! (permission-signature "Read notes.md" "read" "{}")
                    "read read notes.md"
                    "everything else is keyed by its own title")

      ;; approve asks before a shell command...
      (buffer-set-local! buf 'chat-permission-mode 'approve)
      (check-equal! (permit? buf "Run command" "execute" raw) 'ask
                    "the first call asks")

      ;; ...and the answer ends the asking for the whole family
      (permission-always-allow! buf (permission-signature "Run command" "execute" raw))
      (check-equal! (permit? buf "Run command" "execute" raw) 'allow-always
                    "the call that was answered runs")
      (check-equal! (permit? buf "Run command" "execute"
                      "{\"kind\":\"execute\",\"rawInput\":{\"command\":\"gh api repos/b\"}}")
                    'allow-always "and so does the next one in the family")
      (check-equal! (permit? buf "Run command" "execute"
                      "{\"kind\":\"execute\",\"rawInput\":{\"command\":\"curl example.com\"}}")
                    'ask "a verb nobody answered for still asks")

      ;; the rule belongs to the chat that gave it
      (let ((other (t--perm-buf "*zz-always-other*")))
        (buffer-set-local! other 'chat-permission-mode 'approve)
        (check-equal! (permit? other "Run command" "execute" raw) 'ask
                      "another chat never learned it")
        (buffer-kill! other))

      ;; ask mode says every tool call asks, and it outranks a rule
      (buffer-set-local! buf 'chat-permission-mode 'ask)
      (check-equal! (permit? buf "Run command" "execute" raw) 'ask
                    "ask mode means ask, rule or no rule")

      ;; and no answer of the user's reaches past the deny-list
      (buffer-set-local! buf 'chat-permission-mode 'auto)
      (let ((bad "{\"kind\":\"execute\",\"rawInput\":{\"command\":\"git push origin\"}}"))
        (permission-always-allow! buf (permission-signature "Run command" "execute" bad))
        (check-equal! (permit? buf "Run command" "execute" bad) 'ask
                      "an irreversible verb asks even with a rule"))
      (buffer-kill! buf))))

(deftest 'an-inline-session-answers-a-permission-through-the-one-decision
  "M-o asks permit? under the document's stance, like a chat"
  (lambda ()
    (let ((buf (test-buffer! "*zz-inline-perm*" "doc\n")))
      (buffer-set-local! buf 'chat-permission-mode 'auto)
      (check-equal! (llm-inline-permission-verdict buf
                      '(title "eval-scheme" kind "tool" raw "(+ 1 1)"))
                    'allow-always "ordinary work runs unasked in auto")
      (check-equal! (llm-inline-permission-verdict buf
                      '(title "Bash" kind "execute" raw "{\"rawInput\":{\"command\":\"git push --force\"}}"))
                    'ask "a deny-listed verb asks, whatever the stance")
      (buffer-set-local! buf 'chat-permission-mode 'ask)
      (check-equal! (llm-inline-permission-verdict buf
                      '(title "eval-scheme" kind "tool" raw "(buffer-list)"))
                    'ask "the ask stance asks for every tool")
      (check-equal! (llm-inline--option '(options (("allow_once" "Yes") ("reject_once" "No"))) "reject")
                    "reject_once" "the refusal option by prefix")
      (buffer-kill! buf))))

(deftest 'a-word-in-a-search-is-not-an-act
  "the deny-list reads shell commands only: a query or a string that names a
   verb runs, and the same verb in a shell call still asks"
  (lambda ()
    (let ((buf (t--perm-buf "*zz-words*")))
      (buffer-set-local! buf 'chat-presets '(compos))
      (check-equal! (permit? buf "mcp__compos__apropos" "other" "{\"query\":\"whatsapp send message\"}")
                    'allow-always "apropos for send message runs")
      (check-equal! (permit? buf "eval-scheme" "tool" "(mcp-find \"whatsapp|send_message\")")
                    'allow-always "a string in a payload is not a shell command")
      (check-equal! (permit? buf "mcp__compos__eval-scheme" "other"
                             "{\"code\":\"(shell-command->string \\\"git push --force\\\" d)\"}")
                    'ask "a shell push inside eval-scheme still asks")
      (buffer-kill! buf))))
