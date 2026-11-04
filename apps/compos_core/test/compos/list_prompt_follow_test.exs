defmodule Compos.ListPromptFollowTest do
  @moduledoc """
  A list moved from its prompt keeps its row on screen: every window
  showing the list takes the row's point and drops its scroll pin.
  """

  use Compos.Case, async: false

  alias Compos.Core.{Editor}

  # the window's leaf in the frame's tree, as the desktop reads it
  defp leaf(name) do
    Editor.desktop_view().tree |> leaves() |> Enum.find(&(&1.buffer == name))
  end

  defp leaves(%{type: :leaf} = leaf), do: [leaf]
  defp leaves(%{type: :split, children: children}), do: Enum.flat_map(children, &leaves/1)

  test "moving a list under its prompt sets the window's point and drops its scroll pin" do
    eval!(~s{(begin
      (for-each (lambda (n) (buffer-create (string-append "*zz-lpf-" (number->string n) "*")))
                (list 1 2 3 4 5))
      (switch-to-buffer! "*zz-lpf-1*"))})

    eval!(~s{(run-command "ibuffer-prompt")})
    assert eval!("(float-open?)") == "#t"
    win = eval!("(float-window)") |> String.to_integer()

    # the client's own follow scroll reports back: the window is pinned
    Editor.set_client_top(win, 300)
    assert %{manual: true, ctop: 300} = leaf(" *buffers*")

    before = leaf(" *buffers*").point
    eval!(~s{(run-command "minibuffer-next-candidate")})

    assert %{manual: false, ctop: 0, point: point} = leaf(" *buffers*")
    assert point != before
    assert eval!(~s{(window-point #{win})}) == eval!(~s{(buffer-point " *buffers*")})

    eval!("(minibuffer-cancel!)")
    eval!(~s{(for-each (lambda (n) (buffer-kill! (string-append "*zz-lpf-" (number->string n) "*"))) (list 1 2 3 4 5))})
  end
end
