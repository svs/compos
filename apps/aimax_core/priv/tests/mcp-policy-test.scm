;;; mcp-policy-test.scm --- the MCP policy layer: registry, presets, notes.
;;;
;;; What a server IS, how a chat reaches one, and what the model is told
;;; about them. None of this needs a server on the other end.
;;;
;;; Twelve tests stay in ExUnit. Six drive the client against the fake
;;; server in test/support and poll it. Three assert that an eval raises,
;;; which Scheme cannot catch. Three run the tool loop through Elixir.

(domain! 'testing)
(effects! '(write))

;; The registry and the preset list are global, and the live editor's own
;; servers are in them. Every test takes out exactly what it put in.
(define (t--mcp-forget! &rest names)
  (for-each
    (lambda (n)
      (set! *mcp-registry* (remove (lambda (e) (equal? (car e) n)) *mcp-registry*)))
    names))

(define (t--mcp-forget-preset! &rest names)
  (for-each
    (lambda (n)
      (set! *chat-presets* (remove (lambda (e) (equal? (car e) n)) *chat-presets*)))
    names))

(define (t--mcp-kill! &rest names)
  (for-each (lambda (n) (when (buffer-known? n) (buffer-kill! n))) names))

;;; --- the registry -------------------------------------------------------------

(deftest 'an-http-server-translates-to-an-acp-entry
  "a spec with neither a url nor a command is dropped, not guessed at"
  (lambda ()
    (mcp-register! 'zzhttp '(type "http" url "https://zz.test/mcp"
                             headers (Authorization "Bearer zz")))
    (mcp-register! 'zzstdio '(command "zz-bin" args ("--stdio") env (K "v")))
    (mcp-register! 'zzempty '(note "no transport here"))

    (check-equal! (mcp-acp-server 'zzhttp)
                  '(name "zzhttp" type "http" url "https://zz.test/mcp"
                    headers (("Authorization" "Bearer zz")))
                  "the http entry")
    (check-equal! (mcp-acp-server 'zzstdio)
                  '(name "zzstdio" command "zz-bin" args ("--stdio") env (("K" "v")))
                  "the stdio entry")
    (check-false! (mcp-acp-server 'zzempty) "a spec with no transport is #f")

    (check-equal! (map (lambda (s) (plist-get s 'name))
                       (mcp-acp-servers '(zzempty zzhttp)))
                  '("zzhttp") "the dropped one is not in the list")
    (t--mcp-forget! 'zzhttp 'zzstdio 'zzempty)))

;;; --- what the model is told ----------------------------------------------------

(deftest 'the-system-note-names-the-servers-and-the-way-to-call-one
  "a chat that holds no servers is told about none"
  (lambda ()
    (mcp-register! 'zznote '(type "http" url "https://zz.test/mcp"))
    (let ((note (mcp-system-note '(zznote))))
      (check-contains! note "zznote" "the server")
      (check-contains! note "never ssh" "the rule")
      (check-contains! note "mcp-call!" "the call")
      (check-contains! note "unfamiliar operation" "when to search")
      (check-contains! note "do not repeat an equivalent search" "and when to stop"))

    ;; advertising a server the tool gate does not hold sends the agent
    ;; looking for a host
    (check-equal! (mcp-system-note '()) "" "no servers, no note")

    ;; the direct lane carries it in the system text of every turn, for the
    ;; servers THIS chat's presets expose
    (let ((chat (test-buffer! "*zz-note-chat*" "")))
      (buffer-set-local! chat 'agent-slug "zznoteslug")
      (buffer-set-local! chat 'chat-use-tools #t)
      (check-false! (string-contains? (chat-mcp-note chat) "zznote")
                    "a chat with no preset holding it is told nothing")

      (define-preset! 'zznotepreset "a test preset" '(zznote))
      (buffer-set-local! chat 'chat-presets '(zznotepreset))
      (check-contains! (chat-mcp-note chat) "zznote" "the preset puts it in the note")
      (t--mcp-kill! chat))

    (t--mcp-forget! 'zznote)
    (t--mcp-forget-preset! 'zznotepreset)))

(deftest 'chat-tool-list-groups-the-tools-under-the-server-that-serves-them
  "the frozen list IS what the model sees, so the report reads it"
  (lambda ()
    (let ((chat "*zz-list-chat*")
          (here (current-buffer)))
      (define-preset! 'zzlistpack "list pack" '(zzlist))
      (test-buffer! chat "")
      (buffer-set-local! chat 'mode-name "chat-mode")
      (buffer-set-local! chat 'chat-presets '(zzlistpack))
      (buffer-set-local! chat 'chat-tool-specs
        '(("eval-scheme" "Run Scheme in the editor." ())
          ("mcp__zzlist__echo" "Echo back v.\nA second line nobody needs here." "{}")))

      (switch-to-buffer! chat)
      (run-command "chat-tool-list")

      (let ((text (buffer-text "*chat tools*")))
        ;; the header answers "what does this chat hold, and can the model
        ;; see it?"
        (check-contains! text "presets: aimax, zzlistpack" "the presets")
        (check-contains! text "2 tools · " "the count")

        ;; every tool sits under the server that serves it, on one line
        (check-contains! text "\naimax\n  eval-scheme" "the intrinsic bridge heads its own tools")
        (check-contains! text "Run Scheme in the editor." "with its doc")
        (check-contains! text "\nzzlist\n  mcp__zzlist__echo" "and the server heads its own")
        (check-contains! text "Echo back v." "with the first line of its doc")
        (check-false! (string-contains? text "A second line") "and only the first line"))

      (when (buffer-known? here) (switch-to-buffer! here))
      (t--mcp-kill! chat "*chat tools*")
      (t--mcp-forget-preset! 'zzlistpack))))

;;; --- the quiet failures -------------------------------------------------------

(deftest 'unknown-presets-and-servers-stay-quiet-failures
  "a name nobody registered is a message, not a crash"
  (lambda ()
    (check-equal! (preset-servers 'zz-none) '() "an unknown preset holds no servers")
    (let ((mark (string-length (buffer-text "*messages*"))))
      (mcp-ensure! 'zz-unregistered)
      (let ((said (buffer-text "*messages*")))
        (check-contains! (substring said mark (string-length said))
                         "unknown server zz-unregistered" "and it says which one")))))
