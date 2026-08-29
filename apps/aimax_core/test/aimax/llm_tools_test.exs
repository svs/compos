defmodule Aimax.LLMToolsTest do
  @moduledoc "define-tool! registry + the gptel-style native tool_use loop."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  defp stub_chat(fun) do
    Application.put_env(:aimax_core, :llm_chat_fun, fun)
    on_exit(fn -> Application.delete_env(:aimax_core, :llm_chat_fun) end)
  end

  defp has_tool_result?(messages) do
    Enum.any?(messages, fn m ->
      is_list(m.content) and Enum.any?(m.content, &(is_map(&1) and &1[:type] == "tool_result"))
    end)
  end

  describe "registry" do
    test "define-tool! + llm-tool-call round trip" do
      eval!("""
      (define-tool! 'zz-echo "Echo a value." (list (list 'v "string" "value"))
        (lambda (args) (string-append "echo:" (custom--plist-get args 'v))))
      """)

      assert eval!(~s{(llm-tool-call "zz-echo" (list 'v "hi"))}) == ~s{"echo:hi"}
    end

    test "unknown tool reports instead of crashing" do
      assert eval!(~s{(llm-tool-call "no-such" '())}) == ~s{"no such tool: no-such"}
    end

    test "the built-in toolbox exposes concurrent repository reads" do
      specs = eval!("(map car (llm-tool-specs))")
      # Focused repository readers avoid wrapping safe reads in the
      # deliberately conservative eval-scheme tool.
      for t <-
            ~w(eval-scheme apropos apropos-categories describe-function read-file code-outline code-read act ask spotify) do
        assert specs =~ t
      end

      # nothing else ships (test-registered zz-* tools excluded)
      count =
        eval!(
          ~s{(length (filter (lambda (t) (not (string-prefix? "zz-" (symbol->string (car t))))) *llm-tools*))}
        )

      assert count == "10"
      # apropos reads the catalog, and its semantic pass embeds the query
      # through an external service, so the stamp names external and spend.
      # agent-permissions.scm allows the tool anyway: discovery must not ask.
      assert eval!(~s{(nth 3 (assoc "apropos" (llm-tool-specs)))}) == "(read external spend)"
    end

    test "eval-scheme errors suggest the real name with its signature" do
      out = eval!(~s{(llm-tool-call "eval-scheme" (list 'code "(buffer-insert \\"x\\")"))})
      assert out =~ "unbound"
      assert out =~ "did you mean"
      assert out =~ "buffer-insert!"
      # the suggestion carries the public-api doc line, i.e. the signature
      assert out =~ "BYTE-POS"

      # a builtin fed wrong arguments gets its own signature back
      out = eval!(~s{(llm-tool-call "eval-scheme" (list 'code "(buffer-text)"))})
      assert out =~ "bad arguments to buffer-text"
      assert out =~ "(buffer-text NAME)"
    end

    test "apropos searches names, docs, commands, keys and settings by word" do
      # a hit carries its signature, not just its name
      out = eval!(~s{(llm-tool-call "apropos" (list 'query "buffer append"))})
      assert out =~ "buffer-append!"
      assert out =~ "the usual way to add text"
      assert out =~ "(buffer-append! NAME TEXT)"

      # DOC TEXT is searched, which is the whole point: this phrase is in
      # no function name anywhere
      out = eval!(~s{(llm-tool-call "apropos" (list 'query "split"))})
      assert out =~ "split"

      # commands come with their docstrings
      out = eval!(~s{(llm-tool-call "apropos" (list 'query "chat cost"))})
      assert out =~ "chat-cost"

      # every word must appear: this pair shares no entry
      out = eval!(~s{(llm-tool-call "apropos" (list 'query "buffer zzzzquux"))})
      refute out =~ "buffer-append!"

      # a near-miss on a name still lands, marked as such
      out = eval!(~s{(llm-tool-call "apropos" (list 'query "buffer-apend!"))})
      assert out =~ "closest name"

      # internals stay out of the default scope, reachable via scope "all"
      out = eval!(~s{(llm-tool-call "apropos" (list 'query "chat-blocks-push"))})
      refute out =~ "chat-blocks-push!"

      out = eval!(~s{(llm-tool-call "apropos" (list 'query "chat-blocks-push" 'scope "all"))})
      assert out =~ "chat-blocks-push!"

      # a category lists one area whole
      out = eval!(~s{(llm-tool-call "apropos" (list 'query "" 'category "discovery"))})
      assert out =~ "apropos-category"

      # (public! ...) extends the surface at runtime
      eval!(~s{(public! 'zz-shiny "A test entry.")})
      out = eval!(~s{(llm-tool-call "apropos" (list 'query "zz-shiny"))})
      assert out =~ "A test entry."

      # the system skill warns the model off elisp and teaches the split
      assert eval!("*llm-system*") =~ "not Emacs Lisp"
      assert eval!("*llm-system*") =~ "buffer-append!"
      assert eval!("*llm-system*") =~ "public"
      assert eval!("*llm-system*") =~ "project-search-matches"
      assert eval!("*llm-system*") =~ "read-file-numbered"
      assert eval!("*llm-system*") =~ "git-root (default-directory)"
    end

    test "describe-function returns real source for userland fns and commands" do
      # a userland function: full lambda source, body included
      out = eval!(~s{(llm-tool-call "describe-function" (list 'name "chat-thread-context"))})
      assert out =~ "lambda"
      assert out =~ "chat-record"

      # an M-x command (lives in the ETS registry, not the global env)
      out = eval!(~s{(llm-tool-call "describe-function" (list 'name "agent-send"))})
      assert out =~ "M-x command"
      assert out =~ "agent-send-msg!"

      # a builtin is opaque Elixir
      out = eval!(~s{(llm-tool-call "describe-function" (list 'name "car"))})
      assert out =~ "builtin"

      out = eval!(~s{(llm-tool-call "describe-function" (list 'name "zz-nope"))})
      assert out =~ "no function or command"
    end
  end

  describe "buffer editing through eval-scheme" do
    test "the tool switches its logical buffer without changing the user's window" do
      on_exit(fn ->
        Aimax.Core.kill_buffer("*zz-tool-here*")
        Aimax.Core.kill_buffer("*zz-tool-target*")
      end)

      eval!(~s{(buffer-create "*zz-tool-here*")})
      eval!(~s{(buffer-create "*zz-tool-target*")})
      eval!(~s{(define zz-tool-target-name "*zz-tool-target*")})
      eval!(~s{(switch-to-buffer! "*zz-tool-here*")})

      out =
        eval!(
          ~s{(llm-tool-call "eval-scheme" (list 'code "(begin (switch-to-buffer! zz-tool-target-name) (buffer-set-local! (current-buffer) 'zz-tool-touched #t) (current-buffer))"))}
        )

      assert out =~ "*zz-tool-target*"
      assert Buffer.get_local("*zz-tool-target*", "zz-tool-touched") == true
      assert Editor.current_buffer() == "*zz-tool-here*"
    end

    test "the tool reads live buffer text" do
      on_exit(fn -> Aimax.Core.kill_buffer("*zz-doc*") end)
      eval!(~s{(buffer-create "*zz-doc*")})
      eval!(~s{(buffer-append! "*zz-doc*" "Thé quick fox.")})

      assert eval!(~s{(llm-tool-call "eval-scheme" (list 'code "(buffer-text \\"*zz-doc*\\")"))}) =~
               "Thé quick fox."
    end

    test "buffer-replace!: unique replacement (byte-safe); missing and ambiguous rejected" do
      on_exit(fn -> Aimax.Core.kill_buffer("*zz-edit*") end)
      eval!(~s{(buffer-create "*zz-edit*")})
      eval!(~s{(buffer-append! "*zz-edit*" "héllo old world, olde times")})

      # ambiguous: "old" also occurs inside "olde" — buffer untouched
      out = eval!(~s{(buffer-replace! "*zz-edit*" "old" "new")})
      assert out =~ "2 times"
      assert eval!(~s{(buffer-text "*zz-edit*")}) == ~s{"héllo old world, olde times"}

      out = eval!(~s{(buffer-replace! "*zz-edit*" "zebra" "x")})
      assert out =~ "not found"

      assert eval!(~s{(buffer-replace! "*zz-none*" "a" "b")}) =~ "no such buffer"

      # unique match sits after a multibyte char: byte offsets must line up
      out = eval!(~s{(buffer-replace! "*zz-edit*" "old world" "new wörld")})
      assert out == ~s{"edited"}
      assert eval!(~s{(buffer-text "*zz-edit*")}) == ~s{"héllo new wörld, olde times"}
    end
  end

  describe "tool loop" do
    test "four read-only tools from one model round evaluate concurrently" do
      me = self()
      handler = "scheme-read-start-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:aimax, :scheme, :task, :start],
          fn _, measurements, metadata, _ ->
            send(me, {:scheme_read_start, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      eval!("""
      (define-tool! 'zz-parallel-read "Delayed read."
        (list (list 'v "string" "value"))
        (lambda (args)
          (wait-until (lambda () #f) 250 250)
          (custom--plist-get args 'v))
        '(read))
      """)

      stub_chat(fn %{messages: messages} ->
        if has_tool_result?(messages) do
          [%{content: results} | _] = Enum.reverse(messages)
          send(me, {:parallel_results, Enum.map(results, & &1.content)})

          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "parallel reads complete"}]
           }}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" =>
               for n <- 1..4 do
                 %{
                   "type" => "tool_use",
                   "id" => "tu_read_#{n}",
                   "name" => "zz-parallel-read",
                   "input" => %{"v" => Integer.to_string(n)}
                 }
               end
           }}
        end
      end)

      eval!(~s{(llm-with-tools "read four things"
                 (lambda (t) (set-symbol-value! 'zz-parallel-reply t)))})

      starts =
        for _ <- 1..4 do
          assert_receive {:scheme_read_start, %{system_time: time},
                          %{label: "tool zz-parallel-read"}},
                         1_000

          time
        end

      assert Enum.max(starts) - Enum.min(starts) < 150
      assert_receive {:parallel_results, ["1", "2", "3", "4"]}, 1_000

      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-parallel-reply)")) end)
      assert eval!("zz-parallel-reply") == ~s{"parallel reads complete"}
    end

    test "write tools remain on the serial dispatcher" do
      name = "*zz-serial-tools-#{System.unique_integer([:positive])}*"
      on_exit(fn -> Aimax.Core.kill_buffer(name) end)
      eval!(~s{(buffer-create "#{name}")})

      eval!("""
      (define-tool! 'zz-serial-write "Ordered write."
        (list (list 'v "string" "value"))
        (lambda (args)
          (buffer-append! #{inspect(name)} (custom--plist-get args 'v))
          "ok")
        '(write))
      """)

      stub_chat(fn %{messages: messages} ->
        if has_tool_result?(messages) do
          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "serial writes complete"}]
           }}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" =>
               for n <- 1..4 do
                 %{
                   "type" => "tool_use",
                   "id" => "tu_write_#{n}",
                   "name" => "zz-serial-write",
                   "input" => %{"v" => Integer.to_string(n)}
                 }
               end
           }}
        end
      end)

      eval!(~s{(llm-with-tools "write four things"
                 (lambda (t) (set-symbol-value! 'zz-serial-reply t)))})

      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-serial-reply)")) end)
      assert Buffer.text(name) == "1234"
    end

    test "dispatches tool_use, feeds results back, delivers final text" do
      me = self()

      stub_chat(fn %{messages: messages, tools: tools, system: system} ->
        send(me, {:chat, messages, tools, system})

        if has_tool_result?(messages) do
          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "Org font is now ToolFont."}]
           }}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tu_1",
                 "name" => "eval-scheme",
                 "input" => %{"code" => ~s{(customize-save! 'org-font-family "ToolFont")}}
               }
             ]
           }}
        end
      end)

      eval!(~s{(llm-with-tools "change my org font to ToolFont"
                 (lambda (t) (set-symbol-value! 'zz-reply t)))})

      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-reply)")) end)

      assert eval!("zz-reply") == ~s{"Org font is now ToolFont."}
      assert eval!("org-font-family") == ~s{"ToolFont"}

      assert File.read!(Path.join(Aimax.Core.home(), "custom.scm")) =~
               ~s{'(org-font-family "ToolFont")}

      # the request carried the registry as JSON tool defs + the system skill
      assert_received {:chat, _, tools, system}
      evaltool = Enum.find(tools, &(&1.name == "eval-scheme"))
      assert evaltool.input_schema.properties["code"].type == "string"
      assert "code" in evaltool.input_schema.required
      assert system =~ "ai-max"

      # round 2 saw the tool_result
      assert_received {:chat, messages2, _, _}
      assert has_tool_result?(messages2)
    end

    test "a failing tool handler becomes an error result, loop survives" do
      stub_chat(fn %{messages: messages} ->
        if has_tool_result?(messages) do
          [%{content: results} | _] = Enum.reverse(messages)
          [%{content: err} | _] = results

          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "tool said: #{err}"}]
           }}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tu_err",
                 "name" => "eval-scheme",
                 "input" => %{"code" => "(this-does-not-exist)"}
               }
             ]
           }}
        end
      end)

      eval!(~s{(llm-with-tools "break something"
                 (lambda (t) (set-symbol-value! 'zz-err-reply t)))})

      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-err-reply)")) end)
      assert eval!("zz-err-reply") =~ "error:"
    end

    test "runaway tool loop is cut off" do
      stub_chat(fn _ ->
        {:ok,
         %{
           "stop_reason" => "tool_use",
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "tu_n",
               "name" => "eval-scheme",
               "input" => %{"code" => "(+ 1 1)"}
             }
           ]
         }}
      end)

      eval!(~s{(llm-with-tools "loop forever" (lambda (t) (set-symbol-value! 'zz-runaway t)))})

      # error lands in *Messages*, callback never fires
      wait_until(fn ->
        {:ok, text} = Session.eval(~s{(buffer-text "*Messages*")})
        text =~ "exceeded"
      end)

      assert {:ok, "#f"} = Session.eval("(boundp 'zz-runaway)")
    end
  end

  describe "the req_llm wire" do
    alias Aimax.Core.LLM

    test "provider routing: a bare model id is anthropic, prefixes pass through" do
      assert LLM.req_model_spec("claude-sonnet-5") == "anthropic:claude-sonnet-5"
      assert LLM.req_model_spec("openai:gpt-5.6-luna") == "openai:gpt-5.6-luna"

      assert LLM.req_model_spec("openrouter:anthropic/claude-sonnet-5") ==
               "openrouter:anthropic/claude-sonnet-5"

      assert LLM.req_model_spec("deepseek:deepseek-chat") == "deepseek:deepseek-chat"
    end

    test "an unregistered provider fails with a clear no-key error" do
      Session.eval(~s{(set! *llm-keys* '())})
      on_exit(fn -> Session.eval(~s{(set! *llm-keys* '())}) end)

      # no explicit registration -> error, not a silent env fallback
      assert {:error, msg} = LLM.request("hi")
      assert msg =~ "no api key provided"
    end

    test "deepseek routes to api.deepseek.com with its own key, not openrouter's" do
      me = self()

      Application.put_env(:aimax_core, :llm_req_opts,
        req_http_options: [
          plug: fn conn ->
            send(me, {:wire, conn.host, Plug.Conn.get_req_header(conn, "authorization")})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "id" => "chatcmpl-1",
                "object" => "chat.completion",
                "model" => "deepseek-chat",
                "choices" => [
                  %{
                    "index" => 0,
                    "message" => %{"role" => "assistant", "content" => "hi from deepseek"},
                    "finish_reason" => "stop"
                  }
                ],
                "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 3, "total_tokens" => 6}
              })
            )
          end
        ]
      )

      # explicit: use this key for this provider (no env-name convention)
      Session.eval(~s{(register-llm-key! 'deepseek "sk-deepseek")})

      on_exit(fn ->
        Application.delete_env(:aimax_core, :llm_req_opts)
        Session.eval(~s{(set! *llm-keys* '())})
      end)

      LLM.complete("hi", "deepseek:deepseek-chat", fn text -> send(me, {:reply, text}) end)

      assert_receive {:wire, host, auth}, 3_000
      assert host == "api.deepseek.com"
      assert auth == ["Bearer sk-deepseek"]

      assert_receive {:reply, "hi from deepseek"}, 3_000
    end

    test "an explicitly registered key makes the provider's models appear in the picker" do
      Session.eval(~s{(register-llm-key! 'deepseek "sk-explicit")})

      on_exit(fn ->
        Session.eval(~s{(set! *llm-keys* '())})
        Application.delete_env(:req_llm, :deepseek_api_key)
      end)

      models = eval!(~s{(llm-available-models)})
      assert models =~ "deepseek:deepseek-v4-pro"
      assert models =~ "deepseek:deepseek-v4-flash"
    end

    test "the built request carries the tool registry, the system prompt, and cache breakpoints" do
      me = self()

      # capture the actual HTTP request req_llm builds, at the wire
      Application.put_env(:aimax_core, :llm_req_opts,
        req_http_options: [
          plug: fn conn ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(me, {:wire, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "id" => "msg_1",
                "type" => "message",
                "role" => "assistant",
                "model" => "claude-sonnet-5",
                "content" => [%{"type" => "text", "text" => "wired"}],
                "stop_reason" => "end_turn",
                "usage" => %{"input_tokens" => 11, "output_tokens" => 3}
              })
            )
          end
        ]
      )

      # keys.scm owns the chain: a provider with no registered key is an
      # error, not a fallback to the environment
      {:ok, _} = Session.eval(~s{(register-llm-key! 'anthropic "sk-test")})

      on_exit(fn ->
        Application.delete_env(:aimax_core, :llm_req_opts)
        Session.eval(~s{(set! *llm-keys* '())})
      end)

      eval!(~s{(llm-with-tools "hello" (lambda (t) (set-symbol-value! 'zz-wire t)))})
      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-wire)")) end)
      assert eval!("zz-wire") == ~s{"wired"}

      assert_received {:wire, body}

      # the registry crossed as anthropic tool defs
      names = Enum.map(body["tools"] || [], & &1["name"])
      assert "eval-scheme" in names

      # prompt-cache breakpoints survived the port: system, last tool, and
      # the last message each carry cache_control (the api lane's economics)
      assert [%{"cache_control" => %{"type" => "ephemeral"}} | _] = Enum.reverse(body["system"])
      assert %{"cache_control" => %{"type" => "ephemeral"}} = List.last(body["tools"])

      last_block = body["messages"] |> List.last() |> Map.get("content") |> List.last()
      assert %{"cache_control" => %{"type" => "ephemeral"}} = last_block
    end

    test "steered text reaches the next req_llm request as plain user text" do
      me = self()
      request_count = :atomics.new(1, [])
      steer_count = :atomics.new(1, [])

      Application.put_env(:aimax_core, :llm_req_opts,
        req_http_options: [
          plug: fn conn ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            round = :atomics.add_get(request_count, 1, 1)
            send(me, {:steering_wire, round, Jason.decode!(body)})

            text = if round == 1, do: "first answer", else: "final answer"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "id" => "msg_#{round}",
                "type" => "message",
                "role" => "assistant",
                "model" => "claude-sonnet-5",
                "content" => [%{"type" => "text", "text" => text}],
                "stop_reason" => "end_turn",
                "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
              })
            )
          end
        ]
      )

      {:ok, _} = Session.eval(~s{(register-llm-key! 'anthropic "sk-test")})

      on_exit(fn ->
        Application.delete_env(:aimax_core, :llm_req_opts)
        Session.eval(~s{(set! *llm-keys* '())})
      end)

      assert {:ok, "final answer", _usage, "end_turn"} =
               LLM.run_tool_loop(
                 [%{role: "user", content: "start"}],
                 "system",
                 [],
                 "claude-sonnet-5",
                 steer: fn ->
                   if :atomics.add_get(steer_count, 1, 1) == 1,
                     do: ["change course"],
                     else: []
                 end
               )

      assert_received {:steering_wire, 1, _first_body}
      assert_received {:steering_wire, 2, second_body}

      last_user =
        second_body["messages"]
        |> Enum.reverse()
        |> Enum.find(&(&1["role"] == "user"))

      assert [%{"type" => "text", "text" => "change course"}] = last_user["content"]
    end

    # req_llm prices the request against its own model database, and it
    # knows the one thing the token counts don't say: whether the
    # provider's input_tokens already includes the cached tokens. Ours
    # cannot, so its figure — not our table's — is what the ledger keeps.
    test "the ledger records req_llm's cost, not the local table's" do
      ledger = Path.join(Aimax.Core.home(), "llm-usage.jsonl")
      File.rm(ledger)

      # a deliberately absurd local price: if this figure ever reaches the
      # ledger, the local table won and the wiring is broken
      :persistent_term.put(:aimax_llmdb, %{
        "anthropic" => %{
          "models" => %{
            "claude-sonnet-5" => %{
              "cost" => %{
                "input" => 9999.0,
                "output" => 9999.0,
                "cache_read" => 9999.0,
                "cache_write" => 9999.0
              }
            }
          }
        }
      })

      Application.put_env(:aimax_core, :llm_req_opts,
        req_http_options: [
          plug: fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "id" => "msg_1",
                "type" => "message",
                "role" => "assistant",
                "model" => "claude-sonnet-5",
                "content" => [%{"type" => "text", "text" => "priced"}],
                "stop_reason" => "end_turn",
                "usage" => %{
                  "input_tokens" => 11,
                  "output_tokens" => 3,
                  "cache_read_input_tokens" => 100,
                  "cache_creation_input_tokens" => 50
                }
              })
            )
          end
        ]
      )

      {:ok, _} = Session.eval(~s{(register-llm-key! 'anthropic "sk-test")})

      on_exit(fn ->
        Application.delete_env(:aimax_core, :llm_req_opts)
        :persistent_term.erase(:aimax_llmdb)
        Session.eval(~s{(set! *llm-keys* '())})
      end)

      eval!(~s{(llm-with-tools "hello" (lambda (t) (set-symbol-value! 'zz-cost t)))})
      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-cost)")) end)
      wait_until(fn -> File.exists?(ledger) end)

      row =
        ledger |> File.read!() |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

      # the token counts still land verbatim
      assert row["input"] == 11
      assert row["cache_read"] == 100
      assert row["cache_write"] == 50

      # a real price, and nowhere near the absurd local one (which would
      # bill 161 tokens x $9999/M ≈ $1.61)
      assert is_number(row["cost"]) and row["cost"] > 0
      assert row["cost"] < 0.01
    end
  end
end
