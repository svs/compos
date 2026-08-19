defmodule Aimax.OccurTsTest do
  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  @json """
  {
    "one": 1,
    "two": 2
  }
  """

  @query ~S[(pair key: (string) @key)]

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp offset(text, needle), do: text |> :binary.match(needle) |> elem(0)

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
        if Buffer.exists?(buffer), do: Aimax.Core.kill_buffer(buffer)
      end
    end)

    %{source: source}
  end

  test "ts-filter returns structured captures for an explicit grammar", %{source: source} do
    result = eval!(~s[(ts-filter "#{source}" "json" "#{@query}")])

    assert result =~ ~s{capture "key" start}
    assert result =~ ~S{line 2 match "\"one\"" text "  \"one\": 1,"}
    assert result =~ ~S{line 3 match "\"two\"" text "  \"two\": 2"}
  end

  test "occur-ts opens through key dispatch and renders a selectable list", %{source: source} do
    press(["M-s", "t"])
    assert Editor.render_state().minibuffer.prompt == "Tree-sitter query: "

    Editor.minibuffer_set_input(@query)
    press("RET")

    assert Buffer.get_local("*occur-ts*", "mode-name") == "occur-ts-mode"
    assert Buffer.get_local("*occur-ts*", "transient") == true
    assert Buffer.get_local("*occur-ts*", "occur-ts-source") == source

    text = Buffer.text("*occur-ts*")
    assert text =~ "Tree-sitter matches"
    assert text =~ "2 captures · json"
    assert text =~ "2  key"
    assert text =~ ~s{"one": 1}
    assert text =~ ~s{"two": 2}
  end

  test "moving previews captures and RET visits the source", %{source: source} do
    eval!(~s[(occur-ts-open "#{source}" "json" "#{@query}")])
    Editor.set_window_buffer("*occur-ts*")
    eval!(~s[(list-goto-first-entry "*occur-ts*")])

    press("n")
    assert Buffer.point(source) == offset(@json, ~s{"two"})
    assert Editor.current_buffer() == "*occur-ts*"

    press("RET")
    assert Editor.current_buffer() == source
    assert Buffer.point(source) == offset(@json, ~s{"two"})
  end

  test "restoring the mode rebuilds rows from its source locals", %{source: source} do
    eval!(~s[(occur-ts-open "#{source}" "json" "#{@query}")])
    :ok = Buffer.set_read_only("*occur-ts*", false)
    :ok = Buffer.delete_range("*occur-ts*", 0, Buffer.byte_size("*occur-ts*"), source: :editor)
    :ok = Buffer.append("*occur-ts*", "stale", source: :editor)

    eval!(~s[(with-current-buffer "*occur-ts*" (lambda () (set-mode! "occur-ts-mode")))])

    assert Buffer.text("*occur-ts*") =~ ~s{"one": 1}
    assert Buffer.text("*occur-ts*") =~ ~s{"two": 2}
    assert Buffer.read_only?("*occur-ts*")
  end

  test "the public API and command are discoverable" do
    assert eval!(~s[(apropos "capture plists")]) =~ "ts-filter"
    assert eval!(~s[(catalog-entry 'command "occur-ts")]) =~ ~s{effects ("write")}
    assert eval!(~s[(key-for-command "occur-ts")]) == ~s{"M-s t"}
  end
end
