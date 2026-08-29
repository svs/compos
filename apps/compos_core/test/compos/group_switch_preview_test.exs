defmodule Compos.GroupSwitchPreviewTest do
  @moduledoc "C-x b previews the selected buffer in the invoking window."

  use ExUnit.Case

  alias Compos.Core.{Editor, KeyDispatch, Session}

  defp eval!(code) do
    {:ok, value} = Session.eval(code)
    value
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(text), do: text |> String.graphemes() |> press()

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()

    suffix = System.unique_integer([:positive])
    source = "group-preview-source-#{suffix}"
    target = "group-preview-target-#{suffix}"

    eval!(~s{(begin
      (buffer-create "#{target}")
      (buffer-create "#{source}")
      (switch-to-buffer! "#{source}"))})

    on_exit(fn ->
      Editor.minibuffer_close()
      Compos.Core.kill_buffer(source)
      Compos.Core.kill_buffer(target)
      Editor.delete_other_windows()
    end)

    {:ok, source: source, target: target}
  end

  test "typing a candidate previews it and C-g restores the source", context do
    %{source: source, target: target} = context
    home = eval!("(active-window)") |> String.to_integer()

    press(["C-x", "b"])
    type(target)

    assert eval!("(window-buffer #{home})") == Jason.encode!(target)
    assert Editor.render_state().minibuffer != nil

    press("C-g")

    assert eval!("(window-buffer #{home})") == Jason.encode!(source)
    assert Editor.render_state().minibuffer == nil
  end
end
