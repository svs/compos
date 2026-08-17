defmodule Aimax.ChatRenameTest do
  @moduledoc """
  A chat names itself from its own content: after the first turn, then every
  third turn, a small model reads the recent turns and the buffer takes that
  name. The rename keeps the buffer's process, so nothing in it moves.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp buffer(name, text) do
    {:ok, _} = Aimax.Core.create_buffer(name, text: text)

    on_exit(fn ->
      for n <- [name | Aimax.Core.list_buffers()],
          n == name or String.starts_with?(n, "*zz-named"),
          Buffer.exists?(n),
          do: Aimax.Core.kill_buffer(n)
    end)

    name
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    :ok
  end

  describe "the cadence" do
    test "renames on the first turn, then every third one" do
      for {turn, expected} <- [{0, "#f"}, {1, "#t"}, {2, "#f"}, {3, "#f"}, {4, "#t"},
                               {5, "#f"}, {6, "#f"}, {7, "#t"}, {10, "#t"}] do
        assert eval!(~s{(chat-rename-turn? #{turn})}) == expected, "turn #{turn}"
      end
    end

    test "a turn is a user message in the record, or an M-o response" do
      buf = buffer("*zz-turns*", "")
      assert eval!(~s{(chat-turn-count "#{buf}")}) == "0"

      eval!(~s{(buffer-set-local! "#{buf}" 'llm-responses '((0 4) (5 9)))})
      assert eval!(~s{(chat-turn-count "#{buf}")}) == "2"

      # a record wins: that is the surface that has one
      eval!(~s{(begin (chat-record-push! "#{buf}" "user" (list (list "text" "hi")) #f)
                      (chat-record-push! "#{buf}" "assistant" (list (list "text" "ho")) #f))})

      assert eval!(~s{(chat-turn-count "#{buf}")}) == "1"
    end
  end

  describe "the name" do
    test "a title becomes a buffer name: one line, no asterisks, no paths" do
      assert eval!(~s{(chat-rename-clean "  fix the preset merge \\n")}) ==
               ~s{"fix the preset merge"}

      assert eval!(~s{(chat-rename-clean "\\"the *preset* merge/order\\"")}) ==
               ~s{"the preset merge order"}

      assert eval!(~s{(chat-rename-clean "a\\nb")}) == ~s{"a b"}
    end

    test "two chats about one subject get numbered" do
      buffer("*taken subject*", "")
      assert eval!(~s{(chat-rename-unique "taken subject")}) == ~s{"*taken subject 2*"}
      assert eval!(~s{(chat-rename-unique "free subject")}) == ~s{"*free subject*"}
    end

    test "a chat in a file keeps the name of its file" do
      path = Path.join(System.tmp_dir!(), "zz-chat-#{System.unique_integer([:positive])}.chat")
      File.write!(path, "### You\nhi\n")
      on_exit(fn -> File.rm_rf!(path) end)

      eval!(~s{(find-file "#{path}")})
      on_exit(fn -> if Buffer.exists?(path), do: Aimax.Core.kill_buffer(path) end)

      assert eval!(~s{(chat-renameable? "#{path}")}) == "#f"
      assert eval!(~s{(chat-renameable? "*zz-not-a-file*")}) == "#f"

      buf = buffer("*zz-renameable*", "")
      assert eval!(~s{(chat-renameable? "#{buf}")}) == "#t"
    end
  end

  describe "the rename itself" do
    test "the buffer keeps its process, so text, point, locals and undo survive" do
      buf = buffer("*zz-keep*", "one\ntwo\n")
      eval!(~s{(buffer-set-local! "#{buf}" 'chat-presets '(aimax))})
      eval!(~s{(buffer-goto! "#{buf}" 4)})
      :ok = Buffer.insert_at(buf, 8, "three\n")

      assert eval!(~s{(rename-buffer! "#{buf}" "*zz-named-keep*")}) == ~s{"*zz-named-keep*"}

      refute Buffer.exists?(buf)
      assert Buffer.text("*zz-named-keep*") == "one\ntwo\nthree\n"
      assert Buffer.point("*zz-named-keep*") == 4
      assert Buffer.get_local("*zz-named-keep*", "chat-presets") == [sym: "aimax"]

      # the undo history came with it
      assert :ok = Buffer.undo("*zz-named-keep*")
      assert Buffer.text("*zz-named-keep*") == "one\ntwo\n"
    end

    test "a name that is taken is refused, and the buffer keeps the one it has" do
      buf = buffer("*zz-collide*", "x")
      buffer("*zz-named-collide*", "y")

      assert eval!(~s{(rename-buffer! "#{buf}" "*zz-named-collide*")}) == "#f"
      assert eval!(~s{(rename-buffer! "#{buf}" "#{buf}")}) == "#f"
      assert Buffer.exists?(buf)
      assert Buffer.text("*zz-named-collide*") == "y"
    end

    test "a renamed scratch is still its owner's scratch, so C-c s keeps toggling" do
      owner = "zz-owner-#{System.unique_integer([:positive])}"
      {:ok, _} = Aimax.Core.create_buffer(owner, text: "code\n")
      Editor.delete_other_windows()
      Editor.set_window_buffer(owner)

      on_exit(fn ->
        for n <- Aimax.Core.list_buffers(),
            n == owner or String.starts_with?(n, "*scratch:") or
              String.starts_with?(n, "*zz-named"),
            do: Aimax.Core.kill_buffer(n)
      end)

      press(["C-c", "s"])
      scratch = Editor.current_buffer()
      assert scratch == "*scratch:#{owner}*"

      assert eval!(~s{(rename-buffer! "#{scratch}" "*zz-named-scratch*")}) ==
               ~s{"*zz-named-scratch*"}

      assert Buffer.get_local(owner, "scratch-buffer") == "*zz-named-scratch*"

      # from the renamed scratch, back to the owner; and back again to the
      # same buffer, not to a second one under the old name
      Editor.set_window_buffer("*zz-named-scratch*")
      press(["C-c", "s"])
      assert Editor.current_buffer() == owner

      press(["C-c", "s"])
      assert Editor.current_buffer() == "*zz-named-scratch*"
      refute Buffer.exists?(scratch)
    end

    test "the M-o change hook moves with the buffer" do
      buf = buffer("*zz-hooked*", "text\n")
      eval!(~s{(enable-minor-mode! "#{buf}" "llm-mode")})

      assert eval!(~s{(length (filter (lambda (h) (equal? (car h) "#{buf}")) *llm-mode-hooks*))}) ==
               "1"

      eval!(~s{(rename-buffer! "#{buf}" "*zz-named-hooked*")})

      assert eval!(~s{(length (filter (lambda (h) (equal? (car h) "#{buf}")) *llm-mode-hooks*))}) ==
               "0"

      assert eval!(
               ~s{(length (filter (lambda (h) (equal? (car h) "*zz-named-hooked*")) *llm-mode-hooks*))}
             ) == "1"
    end
  end

  describe "the call" do
    test "one call to the naming model per naming turn, and the reply is the name" do
      buf = buffer("*zz-call*", "")
      eval!(~s{(chat-record-push! "#{buf}" "user" (list (list "text" "fix the preset merge")) #f)})

      # stand in for the model: capture the call, answer with a title
      eval!("""
      (begin
        (define *zz-calls* '())
        (set! llm-tools
          (lambda (prompt system specs disp cb usage model)
            (set! *zz-calls* (cons (list prompt model) *zz-calls*))
            (cb "fix the preset merge"))))
      """)

      on_exit(fn ->
        {:ok, _} = Session.eval("(set! llm-tools zz-real-llm-tools)")
      end)

      eval!("(define zz-real-llm-tools llm-tools)")

      eval!(~s{(chat-rename-from-content! "#{buf}")})

      assert eval!("(length *zz-calls*)") == "1"
      assert eval!("(cadr (car *zz-calls*))") == ~s{"openai:gpt-5.6-luna"}
      assert eval!("(car (car *zz-calls*))") =~ "Name this editor conversation"
      assert eval!("(car (car *zz-calls*))") =~ "fix the preset merge"
      assert Buffer.exists?("*fix the preset merge*")

      # the turn is stamped, so a second pass on the same turn is not a
      # second call
      eval!(~s{(chat-rename-from-content! "*fix the preset merge*")})
      assert eval!("(length *zz-calls*)") == "1"
      Aimax.Core.kill_buffer("*fix the preset merge*")
    end

    test "chat-auto-rename off means no call at all" do
      buf = buffer("*zz-off*", "")
      eval!(~s{(chat-record-push! "#{buf}" "user" (list (list "text" "something")) #f)})
      eval!("(define zz-real-llm-tools2 llm-tools)")

      eval!("""
      (begin
        (define *zz-calls2* '())
        (set! llm-tools
          (lambda (prompt system specs disp cb usage model)
            (set! *zz-calls2* (cons prompt *zz-calls2*))
            (cb "nope"))))
      """)

      on_exit(fn ->
        {:ok, _} = Session.eval("(set! llm-tools zz-real-llm-tools2)")
        {:ok, _} = Session.eval("(customize-set! 'chat-auto-rename #t)")
      end)

      eval!("(customize-set! 'chat-auto-rename #f)")
      eval!(~s{(chat-rename-from-content! "#{buf}")})

      assert eval!("(length *zz-calls2*)") == "0"
      assert Buffer.exists?(buf)
    end

    test "the naming turn is part of the conversation, so a reset names again" do
      assert eval!("(if (member 'chat-renamed-at chat-conversation-locals) #t #f)") == "#t"
    end
  end
end
