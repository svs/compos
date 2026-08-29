defmodule Compos.BookmarkTest do
  @moduledoc """
  Bookmark commands through the editor's real key path.

  Record, relocation, persistence, and list policy live in the Scheme tests.
  This test proves the Emacs chords and list visit command dispatch correctly.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  setup do
    id = System.unique_integer([:positive])
    home = eval!("(compos-home)") |> String.trim(~s{"})
    dir = Path.join(home, "zz-bookmark-key-#{id}")
    file = Path.join(dir, "notes.txt")
    store = Path.join(dir, "bookmarks.scd")
    File.mkdir_p!(dir)
    File.write!(file, "alpha\nbeta target\ngamma\n")

    held =
      eval!(
        "(list *bookmarks* *bookmark-current-file* *bookmark-file-mtime* " <>
          "*bookmark-change-count* *bookmark-last-name* bookmark-save-frequency)"
      )

    eval!(~s|(set! *bookmarks* '())|)
    eval!(~s|(set! *bookmark-current-file* #{inspect(store)})|)
    eval!("(set! *bookmark-file-mtime* 0)")
    eval!("(set! *bookmark-change-count* 0)")
    eval!("(set! *bookmark-last-name* #f)")
    eval!("(set! bookmark-save-frequency 1)")
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    eval!(~s|(visit #{inspect(file)})|)

    on_exit(fn ->
      Editor.minibuffer_close()

      for buffer <- [file, "*Bookmark List*"],
          Buffer.exists?(buffer),
          do: Compos.Core.kill_buffer(buffer)

      File.rm_rf!(dir)

      eval!(
        "(let ((v (car (scheme-read #{inspect(held)})))) " <>
          "(set! *bookmarks* (nth 0 v)) " <>
          "(set! *bookmark-current-file* (nth 1 v)) " <>
          "(set! *bookmark-file-mtime* (nth 2 v)) " <>
          "(set! *bookmark-change-count* (nth 3 v)) " <>
          "(set! *bookmark-last-name* (nth 4 v)) " <>
          "(set! bookmark-save-frequency (nth 5 v)))"
      )
    end)

    %{bookmark_path: file}
  end

  test "Emacs bookmark chords set, list, and visit a location", %{bookmark_path: file} do
    eval!("(goto-char! 11)")
    press(["C-x", "r", "m"])
    assert Editor.render_state().minibuffer.prompt =~ "Set bookmark"
    Editor.minibuffer_set_input("target")
    press("RET")

    eval!("(goto-char! 0)")
    press(["C-x", "r", "l"])

    assert Buffer.get_local("*Bookmark List*", "mode-name") == "bookmark-bmenu-mode"
    assert Buffer.text("*Bookmark List*") =~ "target"

    press("RET")
    assert eval!("(current-buffer)") == inspect(file)
    assert eval!("(point)") == "11"
  end
end
