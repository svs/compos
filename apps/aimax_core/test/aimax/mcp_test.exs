defmodule Aimax.MCPTest do
  @moduledoc """
  MCP client: stdio handshake against a real subprocess (the fake server in
  test/support), tool bridging into the LLM loop, and the Scheme policy
  layer (registry, presets, per-chat specs).
  """

  use ExUnit.Case

  alias Aimax.Core.{MCP, Session}

  @fixture Path.expand("../support/fake_mcp_server.exs", __DIR__)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  defp connect!(name) do
    on_exit(fn -> MCP.disconnect(name) end)
    {:ok, _} = MCP.connect(name, %{"command" => "elixir", "args" => [@fixture]})
    wait_until(fn -> MCP.tool_specs([name]) != [] end)
  end

  describe "client" do
    test "handshake publishes qualified specs carrying the raw JSON schema" do
      connect!("fake")

      assert [[name, desc, schema]] = MCP.tool_specs(["fake"])
      assert name == "mcp__fake__echo"
      assert desc =~ "Echo"
      assert Jason.decode!(schema)["required"] == ["v"]

      assert [%{name: "fake", status: :ready, tools: 1}] =
               Enum.filter(MCP.connections(), &(&1.name == "fake"))
    end

    test "call and call_qualified round trip; unknown server reports" do
      connect!("fake2")

      assert {:ok, "echo:hi"} = MCP.call("fake2", "echo", %{"v" => "hi"})
      assert {:ok, "echo:yo"} = MCP.call_qualified("mcp__fake2__echo", %{"v" => "yo"})
      assert {:error, msg} = MCP.call_qualified("mcp__nope__echo", %{})
      assert msg =~ "not connected"
    end

    test "server names are constrained so qualified names split cleanly" do
      assert {:error, _} = MCP.connect("Bad_Name", %{"command" => "true"})
    end

    test "disconnect unpublishes and frees the name" do
      connect!("fake3")
      assert MCP.connected?("fake3")

      MCP.disconnect("fake3")
      wait_until(fn -> not MCP.connected?("fake3") end)
      assert MCP.tool_specs(["fake3"]) == []
    end

    test "a dead command fails loudly instead of hanging" do
      {:ok, _} = MCP.connect("gone", %{"command" => "no-such-binary-zz"})

      wait_until(fn ->
        {:ok, text} = Session.eval(~s{(buffer-text "*messages*")})
        text =~ "gone failed"
      end)
    end
  end

  describe "tool loop bridge" do
    test "mcp__ tools dispatch to the client, not the Scheme dispatcher" do
      connect!("fake4")

      Application.put_env(:aimax_core, :llm_chat_fun, fn %{messages: messages, tools: tools} ->
        assert Enum.any?(tools, &(&1.name == "mcp__fake4__echo"))

        seen_result? =
          Enum.any?(messages, fn m ->
            is_list(m.content) and
              Enum.any?(m.content, &(is_map(&1) and &1[:type] == "tool_result"))
          end)

        if seen_result? do
          [%{content: [%{content: result} | _]} | _] = Enum.reverse(messages)

          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "got #{result}"}],
             "usage" => %{"input_tokens" => 5, "output_tokens" => 7}
           }}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tu_mcp",
                 "name" => "mcp__fake4__echo",
                 "input" => %{"v" => "loop"}
               }
             ],
             "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
           }}
        end
      end)

      on_exit(fn -> Application.delete_env(:aimax_core, :llm_chat_fun) end)

      # dispatcher would blow up if consulted for the mcp tool
      eval!("""
      (llm-tools "go" "sys" (mcp-tool-specs (list "fake4"))
        (lambda (n a) (zz-scheme-dispatcher-must-not-see-mcp-tools))
        (lambda (t) (set-symbol-value! 'zz-mcp-reply t))
        (lambda (u) (set-symbol-value! 'zz-mcp-usage u)))
      """)

      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-mcp-reply)")) end)
      assert eval!("zz-mcp-reply") == ~s{"got echo:loop"}

      # usage callback saw the summed rounds
      assert eval!("(custom--plist-get zz-mcp-usage 'input)") == "15"
      assert eval!("(custom--plist-get zz-mcp-usage 'output)") == "9"
    end
  end

  describe "scheme policy (packages/mcp.scm)" do
    test "registry + preset + chat-extra-tool-specs pull specs once ready" do
      on_exit(fn ->
        MCP.disconnect("zzfake")
        Aimax.Core.kill_buffer("*zz-mcp-chat*")
      end)

      eval!(~s{(mcp-register! 'zzfake (list 'command "elixir" 'args (list "#{@fixture}")))})
      eval!(~s{(define-preset! 'zzweb "test preset" '(zzfake))})
      eval!(~s{(buffer-create "*zz-mcp-chat*")})
      eval!(~s{(buffer-set-local! "*zz-mcp-chat*" 'chat-presets '(zzweb))})

      # first pull triggers the lazy connect; specs appear once ready
      eval!(~s{(chat-extra-tool-specs "*zz-mcp-chat*")})

      wait_until(fn ->
        eval!(~s{(length (chat-extra-tool-specs "*zz-mcp-chat*"))}) == "1"
      end)

      assert eval!(~s{(car (car (chat-extra-tool-specs "*zz-mcp-chat*")))}) =~ "mcp__zzfake__echo"

      # a chat with no presets adds nothing
      assert eval!(~s{(begin (buffer-set-local! "*zz-mcp-chat*" 'chat-presets '())
                             (chat-extra-tool-specs "*zz-mcp-chat*"))}) == "()"
    end

    test "an http server translates to an ACP entry; a spec with neither is dropped" do
      eval!(~s{(mcp-register! 'zzhttp '(type "http" url "https://zz.test/mcp"
                                       headers (Authorization "Bearer zz")))})
      eval!(~s{(mcp-register! 'zzstdio '(command "zz-bin" args ("--stdio") env (K "v")))})
      eval!(~s{(mcp-register! 'zzempty '(note "no transport here"))})

      assert eval!("(mcp-acp-server 'zzhttp)") ==
               ~s{(name "zzhttp" type "http" url "https://zz.test/mcp" } <>
                 ~s{headers (("Authorization" "Bearer zz")))}

      assert eval!("(mcp-acp-server 'zzstdio)") ==
               ~s{(name "zzstdio" command "zz-bin" args ("--stdio") env (("K" "v")))}

      assert eval!("(mcp-acp-server 'zzempty)") == "#f"
      assert eval!("(mcp-acp-servers '(zzempty zzhttp))") =~ "zzhttp"
      refute eval!("(mcp-acp-servers '(zzempty zzhttp))") =~ "zzempty"
    end

    test "mcp-call! connects, waits for the handshake, and returns the tool's text" do
      on_exit(fn -> MCP.disconnect("zzcall") end)
      eval!(~s{(mcp-register! 'zzcall (list 'command "elixir" 'args (list "#{@fixture}")))})

      # never connected: the call does that itself and waits for the tools
      refute MCP.connected?("zzcall")
      assert eval!(~S[(mcp-call! 'zzcall "echo" "{\"v\":\"hi\"}")]) == ~s["echo:hi"]

      # a plist is arguments too — Scheme code should not write JSON by hand
      assert eval!(~s[(mcp-call! 'zzcall "echo" '(v "there"))]) == ~s["echo:there"]
    end

    test "the callback form returns at once and hands the text over later" do
      on_exit(fn -> MCP.disconnect("zzcb") end)
      eval!(~s{(mcp-register! 'zzcb (list 'command "elixir" 'args (list "#{@fixture}")))})

      assert eval!(~s[(mcp-call! 'zzcb "echo" '(v "later")
                        (lambda (ok text) (set-symbol-value! 'zz-cb-reply (list ok text))))]) == ""

      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-cb-reply)")) end)
      assert eval!("zz-cb-reply") == ~s[(#t "echo:later")]
    end

    test "mcp-tools connects first, so the list is never falsely empty" do
      on_exit(fn -> MCP.disconnect("zztools") end)
      eval!(~s{(mcp-register! 'zztools (list 'command "elixir" 'args (list "#{@fixture}")))})

      refute MCP.connected?("zztools")
      assert eval!("(mcp-tools 'zztools)") == ~s[(("echo" "Echo back v."))]

      # the arguments, so nobody guesses parameter names
      schema = eval!(~s[(mcp-tool-schema 'zztools "echo")])
      assert schema =~ "required"
      assert schema =~ "\\\"v\\\""
      assert eval!(~s[(mcp-tool-schema 'zztools "no-such-tool")]) == ~s[""]
    end

    test "mcp-find searches every server's tools the way apropos-api does" do
      on_exit(fn -> MCP.disconnect("zzfind") end)
      eval!(~s{(mcp-register! 'zzfind (list 'command "elixir" 'args (list "#{@fixture}")))})

      # by description, not only by name — "echo" never appears as a word
      # in the request a user actually writes
      assert eval!(~s[(mcp-find "back v" 'zzfind)]) == ~s[(("zzfind" "echo" "Echo back v."))]
      assert eval!(~s[(mcp-find "nothing|missing" 'zzfind)]) == "()"

      # several words, any of which may hit
      assert eval!(~s[(mcp-find "zzz|echo" 'zzfind)]) =~ "echo"
    end

    test "the system note names the servers and the way to call one" do
      eval!(~s{(mcp-register! 'zznote '(type "http" url "https://zz.test/mcp"))})
      note = eval!("(mcp-system-note '(zznote))")

      assert note =~ "zznote"
      assert note =~ "never ssh"
      assert note =~ "mcp-call!"
      assert note =~ "unfamiliar operation"
      assert note =~ "do not repeat an equivalent search"

      # a chat that holds no servers is told about none: advertising one
      # its tool gate does not hold sends the agent looking for a host
      assert eval!("(mcp-system-note '())") == ~s{""}

      # the direct lane carries it in the system text of every turn, for
      # the servers THIS chat's presets expose
      on_exit(fn -> Aimax.Core.kill_buffer("*zz-note-chat*") end)
      eval!(~s{(buffer-create "*zz-note-chat*")})
      eval!(~s{(buffer-set-local! "*zz-note-chat*" 'agent-slug "zznoteslug")})
      eval!(~s{(buffer-set-local! "*zz-note-chat*" 'chat-use-tools #t)})
      refute eval!(~s{(chat-mcp-note "*zz-note-chat*")}) =~ "zznote"

      eval!(~s{(define-preset! 'zznotepreset "a test preset" '(zznote))})
      eval!(~s{(buffer-set-local! "*zz-note-chat*" 'chat-presets '(zznotepreset))})
      assert eval!(~s{(chat-mcp-note "*zz-note-chat*")}) =~ "zznote"
    end

    test "a call to a server that is not there fails with words, not a hang" do
      assert {:error, msg} = Session.eval(~S[(mcp-call! 'zz-not-a-server "echo" "{}")])
      assert msg =~ "not connected"
    end

    test "unknown presets and servers stay quiet failures, not crashes" do
      assert eval!("(preset-servers 'zz-none)") == "()"
      eval!("(mcp-ensure! 'zz-unregistered)")

      {:ok, text} = Session.eval(~s{(buffer-text "*messages*")})
      assert text =~ "unknown server zz-unregistered"
    end
  end
end
