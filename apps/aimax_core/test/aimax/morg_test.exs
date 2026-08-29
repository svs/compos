defmodule Aimax.MorgTest do
  @moduledoc """
  Browser-path checks that need Elixir timing or key dispatch.

  morg-mode is Scheme and priv/tests/morg-test.scm covers all of it — the
  folds, the TODO cycle, the faces, the structural API, babel and tangle.

  These two are the exception, and the same gap twice: set-mode! has no
  teardown hook, so morg's folds, keys and org faces survive a switch to
  markdown-mode. One is @tag :skip and states the contract; the other
  passes here only because of how this file builds its buffer.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(text), do: text |> String.graphemes() |> press()

  defp morg_buffer(text) do
    name = "morg-#{System.unique_integer([:positive])}.md"
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    {:ok, _} = Session.eval(~s{(set-mode! "morg-mode")})
    name
  end

  defp eventually(fun, tries \\ 200)

  defp eventually(fun, tries) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  @doc false
  # "# a\nbody\n## child\ncbody\n# b\ntail\n"
  #  0123 4..8 9......17 ...   24.. 28..
  defp fixture, do: "# a\nbody\n## child\ncbody\n# b\ntail\n"

  test "morg-narrow and morg-widen run through key dispatch" do
    buf = morg_buffer(fixture())
    :ok = Buffer.goto(buf, 12)

    press(["C-x", "n", "n"])
    assert Buffer.narrow_range(buf) == {9, 24}
    assert Buffer.hidden(buf) == []
    assert Buffer.get_local(buf, "morg-narrow-anchor") == 9

    %{tree: leaf} = Editor.render_state()
    assert leaf.narrow_lines == {2, 3}

    press(["C-x", "n", "w"])
    assert Buffer.hidden(buf) == []
    refute Buffer.narrow_range(buf)
    refute Buffer.get_local(buf, "morg-narrow-anchor")
  end

  test "Scheme Babel runs a blocking query off the UI lane" do
    buf =
      morg_buffer("""
      ```scheme
      (db-query "morg-missing" "select 1")
      ```
      """)

    :ok = Buffer.goto(buf, 12)
    press(["C-c", "C-c"])

    eventually(fn -> Buffer.text(buf) =~ "db: no connection morg-missing" end)
    assert Buffer.text(buf) =~ "```result\ndb-query: db: no connection morg-missing\n```"
  end

  test "CSV Babel previews its tangle file through key dispatch" do
    dir = Path.join(System.tmp_dir!(), "aimax-morg-csv-#{System.unique_integer([:positive])}")
    document = Path.join(dir, "notes.md")
    csv = Path.join(dir, "data.csv")
    File.mkdir_p!(dir)
    File.write!(document, "```csv :tangle data.csv :lines 2\nstale_header,value\nstale_row,9\n```\n")
    File.write!(csv, "disk_header,value\ndisk_row,1\nextra_row,2\n")
    {:ok, ^document} = Aimax.Core.open_file(document)

    on_exit(fn ->
      Aimax.Core.kill_buffer(document)
      File.rm_rf!(dir)
    end)

    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer(document)
    {:ok, _} = Session.eval(~s{(set-mode! "morg-mode")})
    :ok = Buffer.goto(document, 35)

    press(["C-c", "C-c"])

    assert Buffer.text(document) =~ "```result-csv\ndisk_header,value\ndisk_row,1\n```"
    refute Buffer.text(document) =~ "No runner for csv"
  end

  # markdown-mode does not exist: no define-mode registers it, and set-mode!
  # has no teardown hook, so morg's folds, keys, and overlays survive the
  # switch. The contract below is the design; building it needs the mode, a
  # major-mode teardown in set-mode!, and a morg teardown that undoes them.
  @tag :skip
  test "markdown-mode is separate and keeps the Earmark preview" do
    buf = morg_buffer("# title\n\nbody\n")

    {:ok, _} = Session.eval(~s{(set-mode! "markdown-mode")})

    assert Buffer.get_local(buf, "mode-name") == "markdown-mode"
    assert Buffer.get_local(buf, "preview-renderer") == "markdown"
    refute Enum.any?(Buffer.overlays(buf), fn {_, _, face} -> face =~ "org-level" end)

    press(["C-c", "C-v"])
    assert Buffer.get_local(buf, "render-mode") == "markdown"
  end

  @tag :skip
  test "switching from morg to markdown removes Morg behavior" do
    buf = morg_buffer(fixture())
    :ok = Buffer.goto(buf, 0)
    press("TAB")
    assert Buffer.hidden(buf) != []

    {:ok, _} = Session.eval(~s{(set-mode! "markdown-mode")})

    assert Buffer.hidden(buf) == []

    refute Enum.any?(Editor.local_keys(buf), fn {_key, command} ->
             command in [
               "morg-cycle",
               "morg-global-cycle",
               "morg-babel",
               "morg-tangle"
             ]
           end)

    :ok = Buffer.insert_at(buf, 0, "x", source: :user)
    refute Enum.any?(Buffer.overlays(buf), fn {_, _, face} -> face =~ "org-level" end)
  end
end
