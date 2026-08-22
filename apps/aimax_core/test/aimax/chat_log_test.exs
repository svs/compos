defmodule Aimax.ChatLogTest do
  @moduledoc """
  Every conversation saves itself: a completed turn writes the chat to
  <home>/chats/<id>.chat in the portable .chat format. One conversation is
  one file; a reset keeps the old file as an archive and clears the id so
  the next conversation starts a new file.
  """

  use ExUnit.Case

  alias Aimax.Core.{Agent, Buffer, Editor, Session}

  defp eval!(src), do: (fn {:ok, p} -> p end).(Session.eval(src))

  # eval a string-valued expression: the printed value is a quoted string
  # literal with JSON-compatible escapes, so one decode recovers it
  defp eval_str!(src), do: src |> eval!() |> Jason.decode!()

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    {:ok, _} = Session.eval("(customize-set! 'chat-auto-rename #f)")

    on_exit(fn ->
      Session.eval("(customize-set! 'chat-auto-rename #t)")
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:"), do: Aimax.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  test "a completed turn writes the conversation; the next turn rewrites the same file" do
    slug =
      eval_str!("""
      (execute* "hi" '(backend "stub" script
        (((type chunk text "Hello.\\n"))
         ((type chunk text "Bye.\\n")))))
      """)

    buf = "*chat:#{slug}*"
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    path = eval_str!(~s[(chat-log-path "#{buf}")])
    assert eventually(fn -> File.exists?(path) end)

    text = File.read!(path)
    assert text =~ "#+chat:"
    assert text =~ "hi"
    assert text =~ "Hello."
    assert text =~ "#+chat-record: "

    # the second turn rewrites the SAME file — one conversation, one file
    eval!(~s[(llm-session-send! "#{slug}" "more")])
    assert eventually(fn -> Buffer.text(buf) =~ "Bye." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    assert eval_str!(~s[(chat-log-path "#{buf}")]) == path
    assert eventually(fn -> File.read!(path) =~ "Bye." end)

    # the log is a v2 .chat: the record reads back whole
    record = eval_str!(~s{(json-encode (chat-file-record (read-file "#{path}")))})
    assert [%{"role" => "user"} | _] = Jason.decode!(record)

    files =
      eval_str!(~s{(json-encode (chat-log-files))})
      |> Jason.decode!()

    assert path in files

    archived =
      eval_str!(~s{(json-encode (chat-log-read "#{path}"))})
      |> Jason.decode!()

    assert archived["path"] == path
    assert archived["prompts"] == ["hi", "more"]
    assert Enum.any?(archived["record"], &(&1["role"] == "assistant"))
  end

  test "reset keeps the file as an archive and clears the id" do
    slug =
      eval_str!("""
      (execute* "hi" '(backend "stub" script
        (((type chunk text "Hello.\\n")))))
      """)

    buf = "*chat:#{slug}*"
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    path = eval_str!(~s[(chat-log-path "#{buf}")])
    assert eventually(fn -> File.exists?(path) end)

    eval!(~s[(begin (switch-to-buffer! "#{buf}") (run-command "chat-reset") #t)])

    # the archive survives; the conversation local is gone, so the next
    # conversation starts a new file
    assert File.exists?(path)
    refute Buffer.get_local(buf, "chat-log-id")
  end

  test "chat-restore reopens a reset conversation from the local archive" do
    slug =
      eval_str!("""
      (execute* "recover this" '(backend "stub" script
        (((type chunk text "Recovered answer.\\n")))))
      """)

    buf = "*chat:#{slug}*"
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    path = eval_str!(~s[(chat-log-path "#{buf}")])
    assert eventually(fn -> File.exists?(path) end)

    eval!(~s[(begin (switch-to-buffer! "#{buf}") (run-command "chat-reset") #t)])
    eval!(~s[(run-command "chat-restore")])
    Editor.minibuffer_set_input(Path.basename(path))
    eval!("(minibuffer-confirm!)")

    assert eval_str!("(current-buffer)") == path
    assert Buffer.get_local(path, "mode-name") == "chat-mode"
    assert Buffer.text(path) =~ "recover this"
    assert Buffer.text(path) =~ "Recovered answer."
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
