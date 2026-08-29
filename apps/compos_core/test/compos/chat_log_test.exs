defmodule Compos.ChatLogTest do
  @moduledoc """
  Every conversation saves itself: a completed turn writes the chat to
  <home>/chats/<id>.chat in the portable .chat format. One conversation is
  one file; a reset keeps the old file as an archive and clears the id so
  the next conversation starts a new file.
  """

  use ExUnit.Case

  alias Compos.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  defp eval!(src), do: (fn {:ok, p} -> p end).(Session.eval(src))

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

  test "the chats list ends with the saved chats and RET revives one" do
    slug =
      eval_str!("""
      (execute* "revive me" '(backend "stub" script
        (((type chunk text "Old answer.\\n")))))
      """)

    buf = "*chat:#{slug}*"
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    path = eval_str!(~s[(chat-log-path "#{buf}")])
    assert eventually(fn -> File.exists?(path) end)

    # archive the chat: the runtime and the buffer both go, the file stays
    Agent.kill(slug)
    Compos.Core.kill_buffer(buf)
    assert eventually(fn -> not Buffer.exists?(buf) end)

    eval!(~s[(run-command "chat-list")])
    rows = Buffer.get_local("*chats*", "list-entries")
    assert path in rows

    # the archive rows sit under every live chat
    live = Enum.count(rows, &Buffer.exists?/1)
    assert Enum.all?(Enum.take(rows, live), &Buffer.exists?/1)

    text = Buffer.text("*chats*")
    assert text =~ "archived"

    # RET on the row reads the file back: the conversation returns
    eval!(~s[(begin (switch-to-buffer! "*chats*") #t)])
    row = Enum.find_index(rows, &(&1 == path))
    eval!(~s[(list-goto-first-entry "*chats*")])
    press(List.duplicate("C-n", row))
    press(["RET"])

    assert Buffer.exists?(path)
    assert Buffer.get_local(path, "mode-name") == "chat-mode"
    assert Buffer.text(path) =~ "revive me"
    assert Buffer.text(path) =~ "Old answer."

    # the revived chat is a live row now, so the archive does not repeat it
    eval!(~s[(run-command "chat-list")])
    saved = Enum.filter(Buffer.get_local("*chats*", "list-entries"), &(&1 == path))
    assert length(saved) == 1

    Compos.Core.kill_buffer(path)
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

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
