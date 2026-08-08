defmodule Aimax.LLMToolsTest do
  @moduledoc "define-tool! registry + the gptel-style native tool_use loop."

  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
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

    test "the built-in toolbox is exactly the four-tool surface" do
      specs = eval!("(map car (llm-tool-specs))")
      for t <- ~w(eval-scheme apropos-api describe-function act) do
        assert specs =~ t
      end

      # nothing else ships (test-registered zz-* tools excluded)
      count =
        eval!(~s{(length (filter (lambda (t) (not (string-prefix? "zz-" (symbol->string (car t))))) *llm-tools*))})

      assert count == "4"
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

    test "apropos-api searches the documented public surface by default" do
      # public hits come back as (name doc) pairs
      out = eval!(~s{(llm-tool-call "apropos-api" (list 'pattern "buffer-append"))})
      assert out =~ "buffer-append!"
      assert out =~ "the usual way to add text"

      # commands are always searchable
      out = eval!(~s{(llm-tool-call "apropos-api" (list 'pattern "^chat"))})
      assert out =~ "chat-send"

      # internals stay out of the default scope, reachable via scope "all"
      out = eval!(~s{(llm-tool-call "apropos-api" (list 'pattern "chat-blocks-push"))})
      refute out =~ "chat-blocks-push!"

      out = eval!(~s{(llm-tool-call "apropos-api" (list 'pattern "chat-blocks-push" 'scope "all"))})
      assert out =~ "chat-blocks-push!"

      # (public! ...) extends the surface at runtime
      eval!(~s{(public! 'zz-shiny "A test entry.")})
      out = eval!(~s{(llm-tool-call "apropos-api" (list 'pattern "zz-shiny"))})
      assert out =~ "A test entry."

      # the system skill warns the model off elisp and teaches the split
      assert eval!("*llm-system*") =~ "NOT Emacs Lisp"
      assert eval!("*llm-system*") =~ "buffer-append!"
      assert eval!("*llm-system*") =~ "public"
    end

    test "describe-function returns real source for userland fns and commands" do
      # a userland function: full lambda source, body included
      out = eval!(~s{(llm-tool-call "describe-function" (list 'name "chat-thread-context"))})
      assert out =~ "lambda"
      assert out =~ "llm-tool-specs"

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
             %{"type" => "tool_use", "id" => "tu_n", "name" => "eval-scheme", "input" => %{"code" => "(+ 1 1)"}}
           ]
         }}
      end)

      eval!(~s{(llm-with-tools "loop forever" (lambda (t) (set-symbol-value! 'zz-runaway t)))})

      # error lands in *messages*, callback never fires
      wait_until(fn ->
        {:ok, text} = Session.eval(~s{(buffer-text "*messages*")})
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

      prev = System.get_env("ANTHROPIC_API_KEY")
      System.put_env("ANTHROPIC_API_KEY", "sk-test")

      on_exit(fn ->
        Application.delete_env(:aimax_core, :llm_req_opts)
        if prev, do: System.put_env("ANTHROPIC_API_KEY", prev), else: System.delete_env("ANTHROPIC_API_KEY")
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
  end
end
