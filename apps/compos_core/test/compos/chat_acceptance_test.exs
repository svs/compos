defmodule Compos.ChatAcceptanceTest do
  @moduledoc """
  Point the acceptance suite at any saved chat and replay it through the
  real editor: the file's user turns are typed into a chat buffer and sent
  with RET, the assistant side plays back from the file on the stub
  backend, and the surface plus the rebuilt record must match the file.

  Target a chat:

      COMPOS_CHAT=~/.compos/chats/<id>.chat mix test \\
        apps/compos_core/test/compos/chat_acceptance_test.exs

  With no target the bundled fixture replays. A failure names what the
  editor could not replay — a block kind with no events, a tool call with
  no card, a turn the record lost — which is the affordance to build next.
  """

  use ExUnit.Case

  alias Compos.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp eval!(src), do: (fn {:ok, p} -> p end).(Session.eval(src))
  defp focus(buf), do: eval!(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!) #t)])

  # eval a string-valued expression: the printed value is a quoted string
  # literal with JSON-compatible escapes, so one decode recovers it
  defp eval_str!(src), do: src |> eval!() |> Jason.decode!()

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    on_exit(fn ->
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:"), do: Compos.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  test "the target chat replays through the key path" do
    path = System.get_env("COMPOS_CHAT") || fixture!()
    assert_replays(path)
  end

  test "a tool call in the record comes back as a card" do
    path = fixture!()
    {buf, _turns} = assert_replays(path)

    text = Buffer.text(buf)
    assert text =~ "▸ tool · read_file"
    assert text =~ "defmodule Foo"

    blocks = Buffer.get_local(buf, "agent-blocks") || []
    assert Enum.any?(blocks, &match?([_, _, "tool", "t1" | _], &1))

    # the completed tool body folds away, exactly as it did live
    body = :binary.match(text, "defmodule Foo") |> elem(0)
    assert Enum.any?(Buffer.hidden(buf), fn {s, e} -> s <= body and body < e end)
  end

  test "a chat the log saved replays" do
    slug =
      eval_str!("""
      (execute* "hi" '(backend "stub" script
        (((type chunk text "Hello there.\\n"))
         ((type chunk text "Bye.\\n")))))
      """)

    buf = "*chat:#{slug}*"
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    eval!(~s[(llm-session-send! "#{slug}" "bye")])
    assert eventually(fn -> Buffer.text(buf) =~ "Bye." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    path = eval_str!(~s[(chat-log-path "#{buf}")])
    assert eventually(fn -> File.read!(path) =~ "Bye." end)
    Compos.Core.kill_buffer(buf)

    assert_replays(path)
  end

  # --- the harness ------------------------------------------------------------

  # Replay PATH: send every user turn through the real key path, then
  # compare the conversation the replay rebuilt with the one the file
  # recorded. Returns {buffer, replayed turns}.
  defp assert_replays(path) do
    # a block kind the replay cannot drive is a missing affordance — name it
    unknown =
      record_in(path)
      |> Enum.flat_map(&(&1["blocks"] || []))
      |> Enum.map(&hd/1)
      |> Enum.uniq()
      |> Kernel.--(["text", "tool-use", "tool-result"])

    assert unknown == [],
           "the record holds block kinds the replay cannot drive yet: #{inspect(unknown)}"

    plan =
      eval_str!(~s{(json-encode (chat-replay-start! "#{path}"))})
      |> Jason.decode!()

    %{"slug" => slug, "prompts" => [first | rest], "turns" => expected} = plan
    buf = "*chat:#{slug}*"

    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: " <> first end),
           "the first prompt was not sent: #{inspect(first)}"

    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end),
           "the first turn did not finish"

    Enum.each(rest, fn prompt ->
      focus(buf)
      Buffer.insert(buf, prompt)
      focus(buf)
      press("RET")

      assert eventually(fn -> Buffer.text(buf) =~ ">>> you: " <> prompt end),
             "the prompt was not sent: #{inspect(prompt)}"

      assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end),
             "the turn did not finish after: #{inspect(prompt)}"
    end)

    replayed = Jason.decode!(eval_str!(~s{(json-encode (reverse (chat-turns "#{buf}")))}))

    assert merged(replayed) == merged(expected),
           "the replayed conversation diverged from the record"

    refute Buffer.text(buf) =~ "⋯ thinking"
    {buf, replayed}
  end

  # The file records an assistant turn per wire message; the replay records
  # one per prompt, with the same text joined. Merge adjacent same-role
  # turns so both sides compare on what was said.
  defp merged(turns) do
    turns
    |> Enum.reduce([], fn [role, text], acc ->
      case acc do
        [[^role, prev] | rest] -> [[role, prev <> text] | rest]
        _ -> [[role, text] | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp record_in(path) do
    case Regex.run(~r/^\#\+chat-record: (.*)$/m, File.read!(Path.expand(path))) do
      [_, json] -> Jason.decode!(json)
      _ -> []
    end
  end

  # a small v2 .chat: two prompts, one tool round
  defp fixture!() do
    record = [
      %{"role" => "user", "blocks" => [["text", "hi"]]},
      %{
        "role" => "assistant",
        "blocks" => [
          ["text", "Let me read the file.\n"],
          ["tool-use", "t1", "read_file", ~s({"path":"foo.ex"})]
        ]
      },
      %{"role" => "user", "blocks" => [["tool-result", "t1", "defmodule Foo do\nend", false]]},
      %{"role" => "assistant", "blocks" => [["text", "It defines Foo.\n"]]},
      %{"role" => "user", "blocks" => [["text", "thanks"]]},
      %{"role" => "assistant", "blocks" => [["text", "Anytime.\n"]]}
    ]

    text = """
    #+chat: (connector "api" permission-mode approve)

    ### You
    hi

    ### Assistant
    Let me read the file.
    It defines Foo.

    ### You
    thanks

    ### Assistant
    Anytime.

    #+chat-record: #{Jason.encode!(record)}
    """

    path =
      Path.join(
        System.tmp_dir!(),
        "compos-replay-fixture-#{System.unique_integer([:positive])}.chat"
      )

    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    path
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
