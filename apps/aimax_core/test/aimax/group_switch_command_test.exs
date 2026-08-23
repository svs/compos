defmodule Aimax.GroupSwitchCommandTest do
  @moduledoc """
  One test: a pull that takes a whole marked set in one act.

  The switcher is Scheme and its tests are Scheme —
  priv/tests/group-switch-test.scm covers founding a group, pull, push,
  pop, the two headings, the three ways to answer, and the layout restore.

  This one was red in every baseline, and it was the test that was
  wrong: it opened ibuffer and pressed the switcher's chords at it.
  ibuffer was this same list from edb89bf until 584f308 gave the
  traditional table back.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, Session}

  defp eval!(code) do
    case Session.eval(code) do
      {:ok, result} -> result
      other -> flunk("Scheme evaluation failed: #{inspect(other)}")
    end
  end

  defp group_id(name) do
    name
    |> then(&eval!(~s{(group-record-create! "#{&1}")}))
    |> Jason.decode!()
  end

  defp labels do
    Editor.render_state().minibuffer.candidates |> Enum.map(& &1.label)
  end

  defp selected do
    case Enum.find(Editor.render_state().minibuffer.candidates, & &1.selected) do
      %{label: label} -> label
      nil -> nil
    end
  end

  defp type(text) do
    text
    |> String.graphemes()
    |> Enum.each(&KeyDispatch.handle_key/1)
  end

  setup do
    Editor.set_pending([])
    Session.eval("(when (minibuffer-state) (minibuffer-cancel!))")

    n = System.unique_integer([:positive])
    first = "groups-first-#{n}"
    second = "groups-second-#{n}"
    third = "groups-third-#{n}"

    for buffer <- [first, second, third], do: Aimax.Core.create_buffer(buffer)

    eval!("""
    (begin
      (set! *group-records* '())
      (set! *group-next-id* 0)
      (set-frame-local! 'current-group #f)
      (set-frame-local! 'previous-group #f)
      (delete-other-windows!)
      (switch-to-buffer! "#{first}"))
    """)

    on_exit(fn ->
      for buffer <- [first, second, third], do: Aimax.Core.kill_buffer(buffer)

      Session.eval("""
      (begin
        (set! *group-records* '())
        (set! *group-next-id* 0)
        (set-frame-local! 'current-group #f)
        (set-frame-local! 'previous-group #f)
        (delete-other-windows!))
      """)
    end)

    %{first: first, second: second, third: third}
  end

  test "marked switcher buffers pull as one operation", %{
    first: first,
    second: second,
    third: third
  } do
    here = group_id("here")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{here}")
      (set-frame-local! 'current-group "#{here}")
      (switch-to-buffer! "#{first}")
      ;; the modal switcher by its own name: ibuffer was this same list
      ;; from edb89bf until 584f308 gave the traditional table back
      (run-command "switch-to-buffer"))
    """)

    # typing is the filter; the verbs go by name, because a key moves
    type(second)
    eval!(~s[(run-command "switch-mark")])

    for _ <- 1..String.length(second), do: eval!(~s[(run-command "switch-del")])

    type(third)
    eval!(~s[(run-command "switch-mark")])
    eval!(~s[(run-command "group-pull-buffer")])

    assert eval!(~s{(buffer-in-group? "#{second}" "#{here}")}) == "#t"
    assert eval!(~s{(buffer-in-group? "#{third}" "#{here}")}) == "#t"
    assert eval!("(frame-local 'current-group)") == Jason.encode!(here)
    assert Editor.current_buffer() == "*switch*"

    KeyDispatch.handle_key("ESC")
    assert Editor.current_buffer() == first
  end


end
