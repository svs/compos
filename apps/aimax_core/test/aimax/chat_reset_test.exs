defmodule Aimax.ChatResetTest do
  @moduledoc "chat-reset wipes the conversation but keeps the surface."

  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  test "a rich group chat resets to its meta card, keeping the group" do
    eval!(~s{(begin
      (switch-to-buffer! (group-chat "resetg"))
      (set-mode! "chat-mode")
      (chat-turn-push! (current-buffer) "user" "hello")
      (buffer-append! (current-buffer) "old transcript junk")
      #t)})

    eval!(~s{(run-command "chat-reset")})

    text = eval!(~s{(buffer-text (current-buffer))})
    assert text =~ "companion · resetg"
    refute text =~ "old transcript junk"
    assert eval!(~s{(chat-turns (current-buffer))}) == "()"
    assert eval!(~s{(buffer-group (current-buffer))}) == ~s{"resetg"}
    # rich again: a fresh mark exists and the input marker is in place
    assert eval!(~s{(if (buffer-local (current-buffer) 'agent-saved-mark) #t #f)}) == "#t"
    assert text =~ "you ▸"
  end

  test "a plain chat resets to its banner" do
    eval!(~s{(begin
      (buffer-create "*plain-reset*")
      (switch-to-buffer! "*plain-reset*")
      (set-mode! "chat-mode")
      (buffer-append! (current-buffer) "### You\\nstale conversation")
      #t)})

    eval!(~s{(run-command "chat-reset")})

    text = eval!(~s{(buffer-text "*plain-reset*")})
    assert text =~ ";; ai-max chat"
    refute text =~ "stale conversation"
  end

  test "a saved .chat file revives as a live conversation" do
    dir = Path.join(System.tmp_dir!(), "chat-revive-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "old-talk.chat")
    File.write!(path, "### You\nremember the plan?\n### Assistant\nYes: ship mail.\n### You\n")

    eval!(~s{(visit "#{path}")})
    assert eval!(~s{(buffer-local (current-buffer) 'mode-name)}) == ~s{"chat-mode"}
    assert eval!(~s{(buffer-text (current-buffer))}) =~ "ship mail"
  end

  test "chat-save writes the transcript as a .chat file" do
    dir = Path.join(System.tmp_dir!(), "chat-save-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "kept")

    eval!(~s{(begin
      (buffer-create "*save-me*")
      (switch-to-buffer! "*save-me*")
      (set-mode! "chat-mode")
      (buffer-append! (current-buffer) "### You\nhello there\n")
      #t)})
    eval!(~s{(run-command "chat-save")})
    # answer the minibuffer prompt
    Enum.each(String.graphemes("#{path}"), &Aimax.Core.KeyDispatch.handle_key/1)
    Aimax.Core.KeyDispatch.handle_key("RET")

    assert File.read!("#{path}.chat") =~ "hello there"
  end

  test "C-x C-s on a non-file chat converts it to a .chat file buffer" do
    dir = Path.join(System.tmp_dir!(), "chat-cxs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "talk.chat")

    eval!(~s{(begin
      (buffer-create "*cxs-chat*")
      (switch-to-buffer! "*cxs-chat*")
      (set-mode! "chat-mode")
      (buffer-append! (current-buffer) "### You\nsave me properly\n")
      #t)})

    eval!(~s{(run-command "save-buffer")})
    Enum.each(String.graphemes("#{path}"), &Aimax.Core.KeyDispatch.handle_key/1)
    Aimax.Core.KeyDispatch.handle_key("RET")

    assert File.read!(path) =~ "save me properly"
    # the buffer became the file buffer, still a chat, old name gone
    assert eval!("(current-buffer)") == ~s{"#{path}"}
    assert eval!(~s{(buffer-local (current-buffer) 'mode-name)}) == ~s{"chat-mode"}
    assert eval!(~s{(buffer-exists? "*cxs-chat*")}) == "#f"

    # from now on C-x C-s just overwrites
    eval!(~s{(begin (end-of-buffer!) (insert! "more words") #t)})
    eval!(~s{(run-command "save-buffer")})
    assert File.read!(path) =~ "more words"
  end

  test "outside a chat it refuses politely" do
    eval!(~s{(begin (switch-to-buffer! "*scratch*") (run-command "chat-reset"))})
    assert eval!(~s{(buffer-exists? "*scratch*")}) == "#t"
  end
end
