defmodule Aimax.CacheEconomicsTest do
  @moduledoc """
  R2's done-when: the api lane stops paying a surcharge for nothing.

  A prompt cache only pays if the prefix repeats. These tests hold the
  three things that used to move it every turn — the system prompt, the
  tool list, and the replayed history — and check that what a turn spends
  is recorded on every way out of it, not only the happy one.
  """

  use ExUnit.Case

  alias Aimax.Core.{Agent, Buffer, Editor, KeyDispatch, LLMDb, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp focus(buf),
    do: {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Application.delete_env(:aimax_core, :llm_req_opts)
      Application.delete_env(:aimax_core, :llm_retry_base_ms)
      Application.delete_env(:aimax_core, :llm_max_tokens)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat") or String.starts_with?(name, "*doc") or
             Buffer.get_local(name, "agent-slug"),
           do: Aimax.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  defp stub_chat(fun), do: Application.put_env(:aimax_core, :llm_chat_fun, fun)

  defp reply(text, usage \\ %{"input_tokens" => 5, "output_tokens" => 2}) do
    {:ok,
     %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => text}],
       "usage" => usage}}
  end

  defp api_chat(name) do
    {:ok, _} = Session.eval(~s{(execute* "" '(connector "api"))})
    _ = name
    "*chat:a1*"
  end

  # --- the prefix ------------------------------------------------------------

  test "editing a watched buffer does not move the system prompt" do
    me = self()
    stub_chat(fn req -> send(me, {:req, req}) && reply("ok") end)

    # a companion chat over one document, tools OFF: the branch that used
    # to inline the whole buffer into the system prompt
    # name the chat from the command's own result: picking it out of the
    # buffer list finds whichever *chat:* another test left behind
    chat =
      eval!(~s[(begin
        (buffer-create "*doc1*")
        (buffer-append! "*doc1*" "the first draft\\n")
        (switch-to-buffer! "*doc1*")
        (set! chat-use-tools #f)
        (run-command "chat")
        (current-buffer))])
      |> String.trim(~s{"})

    assert String.starts_with?(chat, "*chat")

    focus(chat)
    type("read it")
    press(["RET"])
    assert_receive {:req, first}, 2_000

    eval!(~s[(buffer-append! "*doc1*" "a second paragraph appeared\\n")])

    focus(chat)
    type("now read it again")
    press(["RET"])
    assert_receive {:req, second}, 2_000

    on_exit(fn -> Session.eval("(set! chat-use-tools #t)") end)

    # THE invariant: the cached prefix did not move
    assert first.system == second.system

    # the document is named in the system prompt, never quoted there
    assert first.system =~ "*doc1*"
    refute first.system =~ "the first draft"

    # ...it rides the user message, where a change costs one turn
    last = second.messages |> List.last() |> Map.get(:content)
    assert last =~ "a second paragraph appeared"
    assert last =~ "now read it again"
  end

  test "switching between two group buffers does not move the system prompt" do
    me = self()
    stub_chat(fn req -> send(me, {:req, req}) && reply("ok") end)

    # a group of TWO documents, tools OFF: the branch that enumerates the
    # members into the system prompt. group-docs orders them by MRU, so a
    # plain switch used to reorder the list and rewrite the prompt.
    chat =
      eval!(~s[(begin
        (buffer-create "*doc-a*")
        (buffer-append! "*doc-a*" "alpha draft\\n")
        (buffer-create "*doc-b*")
        (buffer-append! "*doc-b*" "beta draft\\n")
        (buffer-set-local! "*doc-a*" 'group "*doc-a*")
        (buffer-set-local! "*doc-b*" 'group "*doc-a*")
        (set! chat-use-tools #f)
        (switch-to-buffer! "*doc-a*")
        (run-command "chat")
        (current-buffer))])
      |> String.trim(~s{"})

    assert String.starts_with?(chat, "*chat")
    on_exit(fn -> Session.eval("(set! chat-use-tools #t)") end)

    # turn 1 with *doc-a* most recently used
    order1 = eval!(~s[(begin (switch-to-buffer! "*doc-a*") (group-docs "*doc-a*"))])
    focus(chat)
    type("first")
    press(["RET"])
    assert_receive {:req, first}, 2_000

    # turn 2 with *doc-b* most recently used — the MRU order flips
    order2 = eval!(~s[(begin (switch-to-buffer! "*doc-b*") (group-docs "*doc-a*"))])
    focus(chat)
    type("second")
    press(["RET"])
    assert_receive {:req, second}, 2_000

    # the switch really reordered the members: the test is not vacuous
    refute order1 == order2

    # both members are in the multi-doc branch of the prompt...
    assert first.system =~ "*doc-a*"
    assert first.system =~ "*doc-b*"

    # THE invariant: the reorder did not move the cached prefix
    assert first.system == second.system
  end

  test "a chat freezes its tool list, says when it is stale, and refreshes on request" do
    me = self()
    stub_chat(fn req -> send(me, {:req, req}) && reply("ok") end)

    buf = api_chat("tools")
    focus(buf)
    type("hello")
    press(["RET"])
    assert_receive {:req, first}, 2_000
    frozen = length(first.tools)
    assert frozen > 0

    # an MCP server finishing its handshake mid-chat, in miniature
    eval!(~s[(define-tool! 'a-late-arrival "registered mid-chat" '() (lambda (a) "hi"))])

    on_exit(fn ->
      Session.eval(
        ~s[(set! *llm-tools* (remove (lambda (t) (equal? (car t) 'a-late-arrival)) *llm-tools*))]
      )
    end)

    focus(buf)
    type("again")
    press(["RET"])
    assert_receive {:req, second}, 2_000

    # the running conversation kept the list it started with
    assert length(second.tools) == frozen
    refute Enum.any?(second.tools, &(&1.name == "a-late-arrival"))

    # ...and the modeline says the editor has moved on
    assert eventually(fn -> Buffer.get_local(buf, "modeline-info") =~ "tools stale" end)

    # adopting the new set is the user's call, and it costs one cache miss
    focus(buf)
    eval!(~s{(run-command "chat-refresh-tools")})
    refute Buffer.get_local(buf, "modeline-info") =~ "tools stale"

    focus(buf)
    type("third")
    press(["RET"])
    assert_receive {:req, third}, 2_000
    assert Enum.any?(third.tools, &(&1.name == "a-late-arrival"))
  end

  # --- what a turn costs -----------------------------------------------------

  test "a cancelled turn still writes its ledger row, priced and attributed" do
    me = self()

    stub_chat(fn req ->
      if Enum.any?(req.messages, &is_list(&1.content)) do
        # round 2: hold the turn open so it can be cancelled mid-flight
        send(me, {:holding, self()})
        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        reply("never seen")
      else
        {:ok,
         %{
           "stop_reason" => "tool_use",
           "content" => [
             %{"type" => "tool_use", "id" => "t1", "name" => "eval-scheme",
               "input" => %{"code" => "(+ 1 1)"}}
           ],
           "usage" => %{"input_tokens" => 400, "output_tokens" => 20,
                        "cache_read_input_tokens" => 900}
         }}
      end
    end)

    ledger = Path.join(Aimax.Core.home(), "llm-usage.jsonl")
    File.rm(ledger)

    buf = api_chat("cancel")
    focus(buf)
    type("run a tool then hang")
    press(["RET"])

    assert_receive {:holding, _task}, 2_000

    focus(buf)
    press(["C-RET"])
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)

    # the round that DID complete is billed: cancelling is not a refund
    assert eventually(fn -> File.exists?(ledger) end)
    row = ledger |> File.read!() |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert row["input"] == 400
    assert row["cache_read"] == 900
    # ...and the row names the chat that spent it
    assert row["slug"] == "a1"

    # the chat's own totals agree with the ledger
    assert eventually(fn ->
             eval!(~s{(plist-get (chat-usage-total "#{buf}") 'cache-read)}) == "900"
           end)
  end

  test "chat-cost states the hit rate, which is the number that matters" do
    stub_chat(fn _req ->
      reply("ok", %{
        "input_tokens" => 100,
        "output_tokens" => 10,
        "cache_read_input_tokens" => 900,
        "cache_creation_input_tokens" => 0
      })
    end)

    buf = api_chat("cost")
    focus(buf)
    type("hello")
    press(["RET"])
    assert eventually(fn -> Buffer.text(buf) =~ "ok" end)

    focus(buf)
    eval!(~s{(run-command "chat-cost")})
    echo = Editor.snapshot().echo

    assert echo =~ "900 read"
    # 900 cached against 1000 billed
    assert echo =~ "90% of input cached"
  end

  test "a reply cut off at the token limit says so" do
    stub_chat(fn _req ->
      {:ok,
       %{
         "stop_reason" => "max_tokens",
         "content" => [%{"type" => "text", "text" => "It begins and then"}],
         "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
       }}
    end)

    buf = api_chat("truncated")
    focus(buf)
    type("write me an essay")
    press(["RET"])

    assert eventually(fn -> Buffer.text(buf) =~ "truncated" end)
    assert Buffer.text(buf) =~ "hit the model's output limit"
  end

  # --- the wire ---------------------------------------------------------------

  test "an overloaded provider is retried, not handed back to the user" do
    Application.put_env(:aimax_core, :llm_retry_base_ms, 1)
    {:ok, counter} = Agent0.start()

    Application.put_env(:aimax_core, :llm_req_opts,
      req_http_options: [
        plug: fn conn ->
          n = Agent0.bump(counter)

          if n < 3 do
            # 529 is Anthropic for "overloaded" — req_llm does not retry it
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(529, Jason.encode!(%{"error" => %{"message" => "overloaded"}}))
          else
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "id" => "msg_1",
                "type" => "message",
                "role" => "assistant",
                "model" => "claude-sonnet-5",
                "content" => [%{"type" => "text", "text" => "through at last"}],
                "stop_reason" => "end_turn",
                "usage" => %{"input_tokens" => 3, "output_tokens" => 3}
              })
            )
          end
        end
      ]
    )

    prev = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "sk-test")

    on_exit(fn ->
      if prev, do: System.put_env("ANTHROPIC_API_KEY", prev), else: System.delete_env("ANTHROPIC_API_KEY")
    end)

    assert {:ok, text} = Aimax.Core.LLM.request("are you there")
    assert text =~ "through at last"
    # two refusals, then the answer — the user never resent anything
    assert Agent0.value(counter) == 3
  end

  # --- the catalog ------------------------------------------------------------

  test "max_tokens comes from the model catalog, not a flat guess" do
    :persistent_term.put(:aimax_llmdb, %{
      "anthropic" => %{
        "models" => %{"claude-sonnet-5" => %{"limit" => %{"output" => 64_000}}}
      }
    })

    on_exit(fn -> :persistent_term.erase(:aimax_llmdb) end)

    assert LLMDb.max_tokens("claude-sonnet-5") == 64_000
    assert LLMDb.max_tokens("anthropic:claude-sonnet-5") == 64_000
    assert LLMDb.max_tokens("openrouter:anthropic/claude-sonnet-5") == 64_000
    assert LLMDb.max_tokens("no-such-model") == nil
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end

defmodule Agent0 do
  @moduledoc "A counter the plug can bump from whatever process Finch runs it in."
  def start, do: Elixir.Agent.start_link(fn -> 0 end)
  def bump(pid), do: Elixir.Agent.get_and_update(pid, fn n -> {n + 1, n + 1} end)
  def value(pid), do: Elixir.Agent.get(pid, & &1)
end
