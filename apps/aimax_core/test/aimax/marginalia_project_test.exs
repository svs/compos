defmodule Aimax.MarginaliaProjectTest do
  @moduledoc """
  Marginalia: M-x candidates carry keybinding + docstring hints.
  Projects: root discovery, git-aware file listing, known-project memory.
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
    test "define-command stores a docstring, command-doc reads it back" do
      {:ok, _} =
        Session.eval(~s{(define-command "mp-frob" "Frob the marginalia test" (lambda () #t))})

      assert {:ok, ~s{"Frob the marginalia test"}} = Session.eval(~s{(command-doc "mp-frob")})
      # 2-arity form still works and reads as empty doc
      {:ok, _} = Session.eval(~s{(define-command "mp-plain" (lambda () #t))})
      assert {:ok, ~s{""}} = Session.eval(~s{(command-doc "mp-plain")})
    end

    test "M-x hints show keybinding and doc" do
      press(["M-x"])
      type("next-line")
      mb = Editor.render_state().minibuffer
      cand = Enum.find(mb.candidates, &(&1.label == "next-line"))
      assert cand, "next-line not among candidates"
      assert cand.hint =~ "C-n"
      press(["C-g"])

      # a doc-only command (no binding) shows just its doc
      {:ok, _} =
        Session.eval(~s{(define-command "mp-docful" "Do the docful thing" (lambda () #t))})

      press(["M-x"])
      type("mp-docful")
      mb = Editor.render_state().minibuffer
      cand = Enum.find(mb.candidates, &(&1.label == "mp-docful"))
      assert cand.hint == "Do the docful thing"
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
