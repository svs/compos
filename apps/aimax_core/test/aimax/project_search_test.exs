defmodule Aimax.ProjectSearchTest do
  @moduledoc """
  project-ripgrep: one rg run, the matches are candidates, the highlighted
  one previews in the invoking window and RET jumps to it.
  project-find-file: the project's open buffers come first, then ".", then
  the git file list.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, out} = Session.eval(src)
    out
  end

  defp window_buffer, do: eval!("(window-buffer (active-window))")

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()

    root = Path.join(System.tmp_dir!(), "ps-proj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.txt"), "one\nneedle here\nthree\n")
    File.write!(Path.join(root, "lib/b.txt"), "alpha\nbeta\nneedle again\n")
    File.write!(Path.join(root, "top.txt"), "nothing to find\n")
    {_, 0} = System.cmd("git", ["init", "-q"], cd: root)

    on_exit(fn ->
      Editor.minibuffer_close()

      for f <- ["lib/a.txt", "lib/b.txt", "top.txt"],
          do: Aimax.Core.kill_buffer(Path.join(root, f))

      Aimax.Core.kill_buffer("*zz-ps*")
      Aimax.Core.kill_buffer(root)
      Editor.delete_other_windows()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  describe "rg--parse" do
    test "reads the path, the line number and the text" do
      out = eval!(~s{(rg--parse "lib/a.txt:2:needle here")})
      assert out =~ ~s{"lib/a.txt:2"}
      assert out =~ ~s{"lib/a.txt"}
      assert out =~ "2"
      assert out =~ ~s{"needle here"}
    end

    test "keeps every colon in the matched text" do
      assert eval!(~s{(rg--parse "a.ex:7:  key: value: more")}) =~ ~s{"key: value: more"}
    end

    test "drops the leading ./ rg prints for an explicit search path" do
      assert eval!(~s{(rg--parse "./lib/a.txt:2:needle")}) =~ ~s{("lib/a.txt:2" "lib/a.txt"}
    end

    test "drops a line that carries no line number" do
      assert {:ok, "#f"} = Session.eval(~s{(rg--parse "rg: no such file")})
      assert {:ok, "#f"} = Session.eval(~s{(rg--parse "")})
    end
  end

  describe "project-ripgrep" do
    test "RET on the first match opens that file at that line", %{root: root} do
      eval!(~s{(project-ripgrep-in "#{root}" "needle")})

      mb = Editor.render_state().minibuffer
      labels = Enum.map(mb.candidates, & &1.label)
      assert "lib/a.txt:2" in labels
      assert "lib/b.txt:3" in labels
      refute Enum.any?(labels, &String.starts_with?(&1, "top.txt"))
      assert Enum.find(mb.candidates, &(&1.label == "lib/a.txt:2")).hint == "needle here"

      press("RET")

      assert eval!("(current-buffer)") == ~s{"#{root}/lib/a.txt"}
      # line 2 starts after "one\n"
      assert eval!("(point)") == "4"
    end

    test "the highlighted match previews, C-g puts the old buffer back", %{root: root} do
      eval!(~s{(begin (buffer-create "*zz-ps*") (switch-to-buffer! "*zz-ps*"))})
      eval!(~s{(project-ripgrep-in "#{root}" "needle")})

      # selection starts on the first match; C-n moves to the second and
      # the invoking window follows it
      press(["C-n"])
      assert window_buffer() == ~s{"#{root}/lib/b.txt"}

      press(["C-g"])
      assert window_buffer() == ~s{"*zz-ps*"}
    end

    test "a pattern with no match says so and opens no prompt", %{root: root} do
      eval!(~s{(project-ripgrep-in "#{root}" "zzz-no-such-text")})
      refute Editor.render_state().minibuffer
    end

    test "the command is registered and C-x p g runs it" do
      assert eval!(~s{(command-doc "project-ripgrep")}) =~ "ripgrep"
      assert eval!(~s{(key-for-command "project-ripgrep")}) == ~s{"C-x p g"}
    end
  end

  describe "project-find-file candidates" do
    test "open buffers come first, then the root, then the rest", %{root: root} do
      eval!(~s{(visit "#{root}/lib/b.txt")})

      cands = eval!(~s{(project-file-candidates "#{root}")})
      assert cands =~ ~s{("lib/b.txt" "open")}
      assert cands =~ ~s{("." "dired")}
      assert cands =~ ~s{("lib/a.txt" "")}

      # an open file is listed once — as the open one
      assert eval!(~s{(project-open-files "#{root}")}) == ~s{("lib/b.txt")}
      refute cands =~ ~s{("lib/b.txt" "")}
    end

    test "a file outside the project does not become a candidate", %{root: root} do
      other = Path.join(System.tmp_dir!(), "ps-other-#{System.unique_integer([:positive])}.txt")
      File.write!(other, "x")
      eval!(~s{(visit "#{other}")})

      assert eval!(~s{(project-open-files "#{root}")}) == "()"

      Aimax.Core.kill_buffer(other)
      File.rm_rf!(other)
    end

    test "a file outside the project stays out of project-buffers", %{root: root} do
      other = Path.join(System.tmp_dir!(), "ps-out-#{System.unique_integer([:positive])}.txt")
      File.write!(other, "x")
      eval!(~s{(visit "#{other}")})
      eval!(~s{(visit "#{root}/lib/a.txt")})

      bufs = eval!(~s{(project-buffers "#{root}")})
      assert bufs =~ "#{root}/lib/a.txt"
      refute bufs =~ other

      Aimax.Core.kill_buffer(other)
      File.rm_rf!(other)
    end

    test "\".\" opens the root in dired", %{root: root} do
      eval!(~s{(project-find-file-in "#{root}")})
      mb = Editor.render_state().minibuffer
      assert Enum.find(mb.candidates, &(&1.label == "."))

      # no buffer is open from this project, so "." is the first candidate
      press("RET")
      assert eval!("(current-buffer)") == ~s{"#{root}"}
      assert eval!(~s{(buffer-local (current-buffer) 'mode-name)}) == ~s{"Dired"}
    end
  end

  describe "project-kill-all" do
    test "the prompt counts the buffers and y kills them", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})
      eval!(~s{(visit "#{root}/lib/b.txt")})
      eval!(~s{(dired-open "#{root}")})
      eval!(~s{(visit "#{root}/top.txt")})

      # the dired listing of the root counts too: its directory is the root
      assert eval!(~s{(project-buffers "#{root}")}) =~ root

      eval!(~s{(run-command "project-kill-all")})
      mb = Editor.render_state().minibuffer
      assert mb.prompt == "Kill 4 buffers in #{Path.basename(root)}? (y or n) "
      # a question offers no candidates
      assert mb.candidates == []

      press("y")
      refute Editor.render_state().minibuffer
      refute eval!("(buffer-list)") =~ root
    end

    test "n keeps every buffer", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})

      eval!(~s{(run-command "project-kill-all")})
      press("n")

      refute Editor.render_state().minibuffer
      assert eval!("(buffer-list)") =~ "#{root}/lib/a.txt"
    end

    test "any other key leaves the question standing", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})

      eval!(~s{(run-command "project-kill-all")})
      press(["x", "q"])

      mb = Editor.render_state().minibuffer
      assert mb.prompt =~ "(y or n)"
      assert mb.input == ""
      # a question is not a completion prompt: the UI reads the style
      assert mb.style == "question"

      press("n")
      assert eval!("(buffer-list)") =~ "#{root}/lib/a.txt"
    end

    test "RET is not an answer: it asks again", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})

      eval!(~s{(run-command "project-kill-all")})
      before = Editor.render_state().minibuffer.prompt
      press("RET")

      assert Editor.render_state().minibuffer.prompt == before
      assert eval!("(buffer-list)") =~ "#{root}/lib/a.txt"

      press("n")
      refute Editor.render_state().minibuffer
    end

    test "a modified file asks to save, and y writes it before the kill", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})
      eval!(~s{(insert! "dirty ")})

      eval!(~s{(run-command "project-kill-all")})
      press("y")

      # the kill question is answered; the save question stands
      assert Editor.render_state().minibuffer.prompt ==
               "Save #{root}/lib/a.txt? (y or n) "

      press("y")
      refute Editor.render_state().minibuffer
      assert File.read!(Path.join(root, "lib/a.txt")) =~ "dirty one"
      refute eval!("(buffer-list)") =~ "#{root}/lib/a.txt"
    end

    test "a modified file you do not save stays open", %{root: root} do
      eval!(~s{(visit "#{root}/lib/b.txt")})
      eval!(~s{(visit "#{root}/lib/a.txt")})
      eval!(~s{(insert! "dirty ")})

      eval!(~s{(run-command "project-kill-all")})
      press(["y", "n"])

      refute Editor.render_state().minibuffer
      bufs = eval!("(buffer-list)")
      assert bufs =~ "#{root}/lib/a.txt"
      refute bufs =~ "#{root}/lib/b.txt"
      # the file on disk keeps what it had
      refute File.read!(Path.join(root, "lib/a.txt")) =~ "dirty"
    end

    test "every modified file gets its own question", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})
      eval!(~s{(insert! "one ")})
      eval!(~s{(visit "#{root}/lib/b.txt")})
      eval!(~s{(insert! "two ")})

      eval!(~s{(run-command "project-kill-all")})
      press("y")
      assert Editor.render_state().minibuffer.prompt =~ "Save "
      press("n")
      assert Editor.render_state().minibuffer.prompt =~ "Save "
      press("n")

      refute Editor.render_state().minibuffer
      bufs = eval!("(buffer-list)")
      assert bufs =~ "#{root}/lib/a.txt"
      assert bufs =~ "#{root}/lib/b.txt"
    end

    test "outside a project the command kills nothing" do
      eval!(~s{(begin (buffer-create "*zz-ps*") (switch-to-buffer! "*zz-ps*"))})
      eval!(~s{(buffer-set-local! "*zz-ps*" 'default-directory "#{System.tmp_dir!()}/")})

      eval!(~s{(run-command "project-kill-all")})
      refute Editor.render_state().minibuffer
      assert eval!("(buffer-list)") =~ "*zz-ps*"
    end

    test "the command is registered and C-x p k runs it" do
      assert eval!(~s{(command-doc "project-kill-all")}) =~ "Kill every buffer"
      assert eval!(~s{(key-for-command "project-kill-all")}) == ~s{"C-x p k"}
    end
  end
end
