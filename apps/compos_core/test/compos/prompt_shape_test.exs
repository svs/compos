defmodule Compos.PromptShapeTest do
  @moduledoc """
  A prompt with a table behind it wears one of three shapes: minibuffer,
  panel, or modal. The minibuffer shape is a DOCK — a pane of the frame,
  spanning it, taking rows from the work rather than covering it. The
  panel and the modal float.
  """

  use Compos.Case

  alias Compos.Core.{Editor, Session}

  setup do
    Editor.minibuffer_close()
    Compos.TestHelpers.one_window!()

    on_exit(fn ->
      Session.eval(~s{(begin (minibuffer-cancel!) (ibuffer-prompt-close! " *buffers*"))})
    end)

    :ok
  end

  # the fractional rectangle of the window showing NAME: (X Y W H)
  defp rect_of(name), do: Enum.find_value(window_layout(), fn {buffer, rect} -> buffer == name && rect end)

  test "the minibuffer shape docks the table across the frame and gives the rows back" do
    eval!(~s{(split-window! 'h 0.5)})
    before = eval!("(length (window-list))")

    # the client measures a window and reports its columns; give the two
    # halves a measurement so the dock has something to estimate from
    Editor.set_window_cols(Map.new(Editor.list_windows(), fn {id, _} -> {id, 90} end))

    eval!(~s{(run-command "ibuffer-prompt-pretty")})

    assert [x, _y, w, _h] = rect_of(" *buffers*")
    # a pane of the FRAME: it starts at the left edge and spans it. A
    # split of the selected window would be a fraction of it instead.
    assert x == 0.0
    assert w == 1.0
    assert eval!(~s{(buffer-local " *buffers*" 'window-class)}) == "#f"
    assert eval!("(and (minibuffer-active?) #t)") == "#t"

    # the table draws at the width it will have, not at the default a
    # window with no client measurement of its own would report. Two
    # half-width windows at 90 columns make the frame 180.
    assert eval!(~s{(list-view-width " *buffers*")}) |> String.to_integer() > 120

    eval!("(minibuffer-cancel!)")
    assert eval!("(length (window-list))") == before
    refute rect_of(" *buffers*")
  end

  test "the shape cycles minibuffer, panel, modal, and the table keeps its filter" do
    eval!(~s{(run-command "ibuffer-prompt-pretty")})
    eval!(~s{(list-set-query! " *buffers*" "zz-no-such-buffer")})
    query = eval!(~s{(list-query " *buffers*")})

    eval!(~s{(run-command "minibuffer-cycle-shape")})
    assert eval!(~s{(buffer-local " *buffers*" 'window-class)}) =~ "popup-bottom"

    eval!(~s{(run-command "minibuffer-cycle-shape")})
    assert eval!(~s{(buffer-local " *buffers*" 'window-class)}) =~ "popup-center"

    eval!(~s{(run-command "minibuffer-cycle-shape")})
    assert eval!(~s{(buffer-local " *buffers*" 'window-class)}) == "#f"
    assert [+0.0, _, 1.0, _] = rect_of(" *buffers*")

    # a shape change moves the surface and nothing else
    assert eval!(~s{(list-query " *buffers*")}) == query
  end
end
