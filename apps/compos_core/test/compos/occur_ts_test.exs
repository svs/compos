defmodule Compos.OccurTsTest do
  @moduledoc """
  What the key path owes, and nothing else.

  The captures, the rendered list, the preview, the visit and the catalog
  row are Scheme policy and live in priv/tests/occur-ts-test.scm. This one
  test stays because it is about dispatch: `M-s t` reaches the command
  through the `M-s` prefix, and the command reads its query in the
  minibuffer before any list exists.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch}

  @json """
  {
    "one": 1,
    "two": 2
  }
  """

  @query ~S[(pair key: (string) @key)]

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  setup do
    source = "occur-ts-source-#{System.unique_integer([:positive])}"
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(source)
    :ok = Buffer.append(source, @json, source: :editor)
    Buffer.set_local(source, "ts-lang", "json")
    Buffer.goto(source, 0)

    on_exit(fn ->
      Editor.minibuffer_close()

      for buffer <- [source, "*occur-ts*"] do
        if Buffer.exists?(buffer), do: Compos.Core.kill_buffer(buffer)
      end
    end)

    %{source: source}
  end

  test "M-s t reaches the command, which reads the query first", %{source: source} do
    press(["M-s", "t"])
    assert Editor.render_state().minibuffer.prompt == "Tree-sitter query: "

    Editor.minibuffer_set_input(@query)
    press("RET")

    assert Buffer.get_local("*occur-ts*", "mode-name") == "occur-ts-mode"
    assert Buffer.get_local("*occur-ts*", "occur-ts-source") == source
    assert Buffer.get_local("*occur-ts*", "occur-ts-query") == @query
  end
end
