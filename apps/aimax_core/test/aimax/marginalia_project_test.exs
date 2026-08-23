defmodule Aimax.MarginaliaProjectTest do
  @moduledoc """
  Marginalia: the prompts that a test must press keys to open.
  Projects: root discovery, git-aware file listing, known-project memory.

  The annotator registry and the column padding are Scheme policy and live
  in priv/tests/marginalia-test.scm. What stays here opens a prompt and
  reads the minibuffer, or builds a git checkout on disk.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer("mp-#{System.unique_integer([:positive])}")
    on_exit(fn -> Editor.minibuffer_close() end)
    :ok
  end

  describe "marginalia" do
    test "find-file candidates carry mode, size and date" do
      root = Path.join(System.tmp_dir!(), "mp-marg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "sub"))
      File.write!(Path.join(root, "a.exs"), "12345")
      File.write!(Path.join(root, "Makefile"), "x")
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, _} = Session.eval(~s{(dired-open "#{root}")})
      press(["C-x", "C-f"])

      hints =
        Editor.render_state().minibuffer.candidates
        |> Map.new(&{&1.label, &1.hint})

      # the icon, the mode a name would open in, then its size, then its date
      assert hints["a.exs"] =~ ~r/^ +elixir-mode +5  [A-Z][a-z]{2} +\d+ \d{2}:\d{2}$/
      assert hints["sub/"] =~ ~r/^ +Dired /
      # nothing in auto-mode-alist claims it, and Fundamental is still a mode
      assert hints["Makefile"] =~ ~r/^ +Fundamental /

      # the columns are one width for the whole set, so the date lands at
      # the same offset on every row however wide the mode and size are
      offsets =
        hints
        |> Map.values()
        |> Enum.map(fn h ->
          [{i, _}] = Regex.run(~r/[A-Z][a-z]{2} +\d+ \d{2}:\d{2}$/, h, return: :index)
          i
        end)
        |> Enum.uniq()

      assert length(offsets) == 1
      press(["C-g"])
    end

    # One annotator serves the prompt and the switcher: the modal list
    # narrows by the same marginalia text the prompt matches.
    test "the switcher narrows by the annotation the marginalia supplies" do
      on_exit(fn ->
        for b <- ["*mp-ga*", "*mp-gb*", "*switch*"], do: Aimax.Core.kill_buffer(b)
      end)

      {:ok, _} =
        Session.eval(~s{(begin
          (buffer-create "*mp-ga*")
          (buffer-create "*mp-gb*")
          (buffer-set-local! "*mp-ga*" 'group "work/dishwasher")
          (run-command "ibuffer"))})

      assert Aimax.Core.Buffer.text("*switch*") =~ "*mp-gb*"

      # the group is nowhere in the name: it is what the annotator says
      type("dishwasher")
      text = Aimax.Core.Buffer.text("*switch*")
      assert text =~ "*mp-ga*"
      refute text =~ "*mp-gb*"
      assert text =~ "/dishwasher"
      assert {:ok, ~s{"*mp-ga*"}} = Session.eval(~s{(car (list-current "*switch*"))})
      press(["ESC"])
    end

    test "M-x hints show keybinding and doc" do
      press(["M-x"])
      type("next-line")
      mb = Editor.render_state().minibuffer
      cand = Enum.find(mb.candidates, &(&1.label == "next-line"))
      assert cand, "next-line not among candidates"
      assert cand.hint =~ "C-n"
      press(["C-g"])

      # a doc-only command keeps the binding column, blank — that is what
      # makes every doc in the list start in the same place
      {:ok, _} =
        Session.eval(~s{(define-command "mp-docful" "Do the docful thing" (lambda () #t))})

      press(["M-x"])
      type("mp-docful")
      mb = Editor.render_state().minibuffer
      cand = Enum.find(mb.candidates, &(&1.label == "mp-docful"))
      assert cand.hint =~ ~r/^ +Do the docful thing$/
      press(["C-g"])
    end
  end

  describe "projects" do
    setup do
      root = Path.join(System.tmp_dir!(), "mp-proj-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "lib/deep"))
      File.write!(Path.join(root, "lib/deep/a.txt"), "a")
      File.write!(Path.join(root, "top.txt"), "t")
      {_, 0} = System.cmd("git", ["init", "-q"], cd: root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "project-root-from walks up to the .git marker", %{root: root} do
      assert {:ok, ~s{"#{root}"}} ==
               Session.eval(~s{(project-root-from "#{root}/lib/deep")})

      assert {:ok, "#f"} = Session.eval(~s{(project-root-from "#{System.tmp_dir!()}")})
    end

    test "project-files lists tracked and untracked-but-not-ignored", %{root: root} do
      File.write!(Path.join(root, ".gitignore"), "top.txt\n")
      {:ok, files} = Session.eval(~s{(project-files "#{root}")})
      assert files =~ "lib/deep/a.txt"
      refute files =~ "top.txt"
    end

    test "visiting a file remembers its project", %{root: root} do
      {:ok, _} = Session.eval(~s{(visit "#{root}/top.txt")})
      {:ok, known} = Session.eval("(known-projects)")
      assert known =~ root
    end
  end
end
