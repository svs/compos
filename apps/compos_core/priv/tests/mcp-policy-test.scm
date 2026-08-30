;;; mcp-policy-test.scm --- the MCP policy layer: registry, presets, notes.
;;;
;;; What a server IS, how a chat reaches one, and what the model is told
;;; about them. None of this needs a server on the other end.
;;;
;;; Seven tests stay in ExUnit, and each is the bridge: six drive the
;;; Elixir client API — MCP.connect, MCP.call, MCP.tool_specs — and one
;;; runs the tool loop through an Application.put_env stub.
;;;
;;; An eighth would move but cannot yet: mcp-call!'s CALLBACK form hands
;;; its text to a closure created inside the test, and a closure created
;;; mid-eval points at a frame no other process can resolve, so the reply
;;; is dropped in silence. See docs/BUG-escaped-closure-handlers.md.

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
        (check-contains! text "presets: compos, zzlistpack" "the presets")
        (check-contains! text "2 tools · " "the count")

        ;; every tool sits under the server that serves it, on one line
        (check-contains! text "\ncompos\n  eval-scheme" "the intrinsic bridge heads its own tools")
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
    (let ((mark (string-length (messages-text))))
      (mcp-ensure! 'zz-unregistered)
      (let ((said (messages-text)))
        (check-contains! (substring said mark (string-length said))
                         "unknown server zz-unregistered" "and it says which one")))))

;;; --- the fake server -------------------------------------------------------------
;;; A test writes its own: the registry takes a command and arguments, so
;;; the fixture is a file this test lays down and removes. priv/tests must
;;; not reach into the Elixir test tree, and a release ships no test/.

(define t--mcp-dir (string-append (compos-home) "/zz-mcp"))
(define t--mcp-server (string-append t--mcp-dir "/fake_mcp_server.exs"))

(define t--mcp-script "# Minimal MCP server over stdio for tests: newline-delimited JSON-RPC,\n# initialize handshake, one tool (\"echo\"). Uses OTP's :json — no deps, so it\n# runs as `elixir fake_mcp_server.exs` straight from a Port.\n#\n# It advertises resources AND prompts but only implements resources/list:\n# prompts/list falls through to -32601, which is exactly what a real server\n# that overstates its capabilities does, and the client must survive it.\ndefmodule FakeMCP do\n  def loop do\n    case IO.gets(\"\") do\n      :eof -> :ok\n      {:error, _} -> :ok\n      line ->\n        line |> String.trim() |> handle()\n        loop()\n    end\n  end\n\n  defp handle(\"\"), do: :ok\n\n  defp handle(line) do\n    case :json.decode(line) do\n      %{\"method\" => \"initialize\", \"id\" => id, \"params\" => params} ->\n        reply(id, %{\n          protocolVersion: params[\"protocolVersion\"],\n          capabilities: %{tools: %{}, resources: %{}, prompts: %{}},\n          serverInfo: %{name: \"fake-mcp\", version: \"0.0.1\"}\n        })\n\n      %{\"method\" => \"resources/list\", \"id\" => id} ->\n        reply(id, %{\n          resources: [\n            %{uri: \"file:///fake.txt\", name: \"fake.txt\", description: \"A fake file.\"}\n          ]\n        })\n\n      %{\"method\" => \"tools/list\", \"id\" => id} ->\n        reply(id, %{\n          tools: [\n            %{\n              name: \"echo\",\n              description: \"Echo back v.\",\n              inputSchema: %{\n                type: \"object\",\n                properties: %{v: %{type: \"string\", description: \"value to echo\"}},\n                required: [\"v\"]\n              }\n            }\n          ]\n        })\n\n      %{\"method\" => \"tools/call\", \"id\" => id, \"params\" => params} ->\n        v = params[\"arguments\"][\"v\"] || \"\"\n        reply(id, %{content: [%{type: \"text\", text: \"echo:\" <> v}]})\n\n      %{\"method\" => _, \"id\" => id} ->\n        send_msg(%{jsonrpc: \"2.0\", id: id, error: %{code: -32601, message: \"method not found\"}})\n\n      _notification ->\n        :ok\n    end\n  end\n\n  defp reply(id, result), do: send_msg(%{jsonrpc: \"2.0\", id: id, result: result})\n\n  # the client may disconnect mid-reply; a dead stdout is not news\n  defp send_msg(msg) do\n    msg |> :json.encode() |> IO.iodata_to_binary() |> IO.puts()\n  catch\n    _, _ -> :ok\n  end\nend\n\nFakeMCP.loop()\n")

(define (t--mcp-setup!)
  (shell-command->string (string-append "rm -rf " t--mcp-dir))
  (make-directory! t--mcp-dir)
  (write-file! t--mcp-server t--mcp-script)
  t--mcp-server)

(define (t--mcp-register! name)
  (mcp-register! name (list 'command "elixir" 'args (list t--mcp-server)))
  name)

(define (t--mcp-forget! &rest names)
  (for-each
    (lambda (n)
      (mcp-disconnect! n)
      (set! *mcp-registry* (remove (lambda (e) (equal? (car e) n)) *mcp-registry*)))
    names)
  (shell-command->string (string-append "rm -rf " t--mcp-dir)))

(deftest 'mcp-call-connects-waits-for-the-handshake-and-answers
  "the call does the connecting, so a caller never has to"
  (lambda ()
    (t--mcp-setup!)
    (t--mcp-register! 'zzcall)
    ;; never connected: the call does that itself and waits for the tools
    (check-equal! (mcp-call! 'zzcall "echo" "{\"v\":\"hi\"}") "echo:hi" "a JSON argument")
    ;; a plist is arguments too — Scheme code should not write JSON by hand
    (check-equal! (mcp-call! 'zzcall "echo" '(v "there")) "echo:there" "and a plist")
    (t--mcp-forget! 'zzcall)))

(deftest 'mcp-tools-connects-first-so-the-list-is-never-falsely-empty
  "an empty list from an unconnected server is a lie"
  (lambda ()
    (t--mcp-setup!)
    (t--mcp-register! 'zztools)
    (check-equal! (mcp-tools 'zztools) '(("echo" "Echo back v.")) "the tool and its doc")

    ;; the arguments, so nobody guesses parameter names
    (let ((schema (mcp-tool-schema 'zztools "echo")))
      (check-contains! schema "required" "the schema names what is required")
      (check-contains! schema "\"v\"" "and the parameter"))
    (check-equal! (mcp-tool-schema 'zztools "no-such-tool") "" "an unknown tool has none")
    (t--mcp-forget! 'zztools)))

(deftest 'mcp-find-searches-every-servers-tools
  "by description, not only by name"
  (lambda ()
    (t--mcp-setup!)
    (t--mcp-register! 'zzfind)
    ;; "echo" never appears as a word in the request a user actually writes
    (check-equal! (mcp-find "back v" 'zzfind) '(("zzfind" "echo" "Echo back v."))
                  "the description answers")
    (check-equal! (mcp-find "nothing|missing" 'zzfind) '() "a miss is empty")
    (check-contains! (value->string (mcp-find "zzz|echo" 'zzfind)) "echo"
                     "and several words, any of which may hit")
    (t--mcp-forget! 'zzfind)))

(deftest 'a-preset-pulls-a-servers-specs-into-a-chat-once-ready
  "the first pull triggers the lazy connect"
  (lambda ()
    (t--mcp-setup!)
    (t--mcp-register! 'zzfake)
    (define-preset! 'zzweb "test preset" '(zzfake))
    (let ((chat (test-buffer! "*zz-mcp-chat*" "")))
      (buffer-set-local! chat 'chat-presets '(zzweb))
      (chat-extra-tool-specs chat)

      ;; the intrinsic compos bridge rides every chat, so count THIS
      ;; server's tools rather than the whole list
      (check-true! (wait-until
                     (lambda ()
                       (= 1 (length (filter (lambda (s) (string-prefix? "mcp__zzfake__" (car s)))
                                            (chat-extra-tool-specs chat)))))
                     20000 100)
                   "the specs appear once the server is ready")

      ;; dropping the preset drops its tools; the compos bridge stays
      (buffer-set-local! chat 'chat-presets '())
      (check-false! (string-contains? (value->string (chat-extra-tool-specs chat)) "mcp__zzfake__")
                    "and the tools go with the preset")
      (buffer-kill! chat))
    (set! *chat-presets* (remove (lambda (e) (equal? (car e) 'zzweb)) *chat-presets*))
    (t--mcp-forget! 'zzfake)))

(deftest 'a-call-to-a-server-that-is-not-there-fails-with-words
  "not a hang, and not a silent nothing"
  (lambda ()
    (let ((out (eval-string-safe "(mcp-call! 'zz-not-a-server \"echo\" \"{}\")")))
      (check-equal! (car out) 'error "the call fails")
      (check-contains! (cadr out) "not connected" "and says why"))))
