defmodule Compos.GroupSwitchPreviewTest do
  @moduledoc "C-x b previews the selected buffer in the invoking window."

  use Compos.Case

  alias Compos.Core.{Editor}

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()
    eval!("(panes-choose-layout! #f)")

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

  test "C-u C-x b opens the picked buffer in another window", context do
    home = eval!("(active-window)") |> String.to_integer()

    press(["C-u", "C-x", "b"])
    type(context.target)
    assert eval!("(window-buffer #{home})") == Jason.encode!(context.target)

    press("RET")

    assert eval!("(window-buffer #{home})") == Jason.encode!(context.source)
    assert length(Editor.list_windows()) == 2
    refute eval!("(active-window)") |> String.to_integer() == home
    assert Editor.current_buffer() == context.target
  end
end
