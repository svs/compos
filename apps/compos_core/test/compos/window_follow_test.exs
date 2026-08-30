defmodule Compos.WindowFollowTest do
  @moduledoc """
  A window a reader scrolled by wheel is pinned (`manual`): it keeps its
  pixel offset and does not follow point. A page that replaces its text
  and places point asks every window on it to follow point again.
  """

  use ExUnit.Case

  alias Compos.Core.{Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    :ok
  end

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp active_leaf do
    state = Editor.render_state()
    find_leaf(state.tree, state.active)
  end

  defp find_leaf(%{type: :leaf, id: id} = leaf, id), do: leaf
  defp find_leaf(%{type: :leaf}, _), do: nil

  defp find_leaf(%{type: :split, children: children}, id),
    do: Enum.find_value(children, &find_leaf(&1, id))

  defp pin_active_window! do
    %{active: win} = Editor.snapshot()
    :ok = Editor.set_client_top(win, 480)
    leaf = active_leaf()
    assert leaf.manual == true
    assert leaf.ctop == 480
  end

  test "buffer-windows-follow-point! drops the pin on every window showing the buffer" do
    name = "*zz-follow-#{System.unique_integer([:positive])}*"
    eval!(~s{(begin (buffer-create "#{name}") (switch-to-buffer! "#{name}"))})
    pin_active_window!()

    assert eval!(~s{(buffer-windows-follow-point! "#{name}")}) == "#t"

    leaf = active_leaf()
    assert leaf.manual == false
    assert leaf.ctop == 0
    assert leaf.top == 0
    eval!(~s{(buffer-kill! "#{name}")})
  end

  test "a window on another buffer keeps its pin" do
    name = "*zz-follow-other-#{System.unique_integer([:positive])}*"
    eval!(~s{(begin (buffer-create "#{name}") (switch-to-buffer! "#{name}"))})
    pin_active_window!()

    assert eval!(~s{(buffer-windows-follow-point! "*zz-not-shown*")}) == "#t"

    assert active_leaf().manual == true
    eval!(~s{(buffer-kill! "#{name}")})
  end

  test "a browse page render opens at the top in a window scrolled down the old page" do
    name = "*zz-browse-follow-#{System.unique_integer([:positive])}*"
    eval!(~s{(begin (buffer-create "#{name}") (switch-to-buffer! "#{name}"))})
    pin_active_window!()

    eval!(~s{(web--render! "#{name}" "# A page\n\nSome text on the page.\n")})

    assert eval!(~s{(buffer-point "#{name}")}) == "0"
    leaf = active_leaf()
    assert leaf.manual == false
    assert leaf.ctop == 0
    eval!(~s{(buffer-kill! "#{name}")})
  end
end
