defmodule Aimax.GroupSwitchCommandTest do
  @moduledoc """
  The group switcher, driven through the keys.

  The records themselves — the stable id, the membership set, the dangling
  id, dissolve, the layouts and the frame context — are Scheme policy and
  live in priv/tests/group-records-test.scm.
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

  test "new from visible preserves old memberships and the layout", %{
    first: first,
    second: second
  } do
    old = group_id("old")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{old}")
      (delete-other-windows!)
      (switch-to-buffer! "#{first}")
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! "#{second}")
      (run-command "group-new-from-visible"))
    """)

    type("visible")
    KeyDispatch.handle_key("RET")

    id = eval!(~s{(group-resolve-id "visible")}) |> Jason.decode!()

    assert eval!(~s{(buffer-in-group? "#{first}" "#{old}")}) == "#t"
    assert eval!(~s{(buffer-in-group? "#{first}" "#{id}")}) == "#t"
    assert eval!(~s{(buffer-in-group? "#{second}" "#{id}")}) == "#t"
    assert eval!("(frame-local 'current-group)") == Jason.encode!(id)
    assert eval!(~s{(equal? (group-layout "#{id}") (window-tree))}) == "#t"
  end

  test "cancelled group creation changes no group state", %{first: first} do
    before = eval!("(window-tree)")

    eval!(~s{(run-command "group-new-from-buffer")})
    KeyDispatch.handle_key("C-g")

    assert eval!("(group-ids)") == "()"
    assert eval!("(frame-local 'current-group)") == "#f"
    assert eval!(~s{(buffer-group-ids "#{first}")}) == "()"
    assert eval!("(window-tree)") == before
  end

  test "pull adds the current group without switching context", %{
    first: first,
    second: second
  } do
    here = group_id("here")
    there = group_id("there")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{here}")
      (buffer-add-group! "#{second}" "#{there}")
      (set-frame-local! 'current-group "#{here}")
      (switch-to-buffer! "#{first}")
      (run-command "group-pull-buffer"))
    """)

    labels = Editor.render_state().minibuffer.candidates |> Enum.map(& &1.label)
    assert second in labels

    type(second)
    KeyDispatch.handle_key("RET")

    assert eval!(~s{(buffer-in-group? "#{second}" "#{here}")}) == "#t"
    assert eval!(~s{(buffer-in-group? "#{second}" "#{there}")}) == "#t"
    assert eval!("(frame-local 'current-group)") == Jason.encode!(here)
    assert Editor.current_buffer() == first
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
      (run-command "ibuffer"))
    """)

    type(second)
    KeyDispatch.handle_key("C-SPC")

    for _ <- 1..String.length(second), do: KeyDispatch.handle_key("DEL")

    type(third)
    KeyDispatch.handle_key("C-SPC")
    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("l")

    assert eval!(~s{(buffer-in-group? "#{second}" "#{here}")}) == "#t"
    assert eval!(~s{(buffer-in-group? "#{third}" "#{here}")}) == "#t"
    assert eval!("(frame-local 'current-group)") == Jason.encode!(here)
    assert Editor.current_buffer() == "*switch*"

    KeyDispatch.handle_key("ESC")
    assert Editor.current_buffer() == first
  end

  test "push adds an existing destination without leaving the source", %{first: first} do
    source = group_id("source")
    destination = group_id("destination")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{source}")
      (set-frame-local! 'current-group "#{source}")
      (switch-to-buffer! "#{first}")
      (run-command "group-push-buffer"))
    """)

    labels = Editor.render_state().minibuffer.candidates |> Enum.map(& &1.label)
    assert "New group" in labels
    assert "destination" in labels

    type("destination")
    KeyDispatch.handle_key("RET")

    assert eval!(~s{(buffer-in-group? "#{first}" "#{source}")}) == "#t"
    assert eval!(~s{(buffer-in-group? "#{first}" "#{destination}")}) == "#t"
    assert eval!("(frame-local 'current-group)") == Jason.encode!(source)
    assert Editor.current_buffer() == first
  end

  test "push can create a destination without entering it", %{first: first} do
    source = group_id("source")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{source}")
      (set-frame-local! 'current-group "#{source}")
      (switch-to-buffer! "#{first}")
      (run-command "group-push-buffer"))
    """)

    type("New group")
    KeyDispatch.handle_key("RET")
    type("created")
    KeyDispatch.handle_key("RET")

    created = eval!(~s{(group-resolve-id "created")}) |> Jason.decode!()

    assert eval!(~s{(buffer-in-group? "#{first}" "#{created}")}) == "#t"
    assert eval!("(frame-local 'current-group)") == Jason.encode!(source)
  end

  test "pop removes only the current group and replaces a visible buffer", %{
    first: first,
    second: second
  } do
    here = group_id("here")
    shared = group_id("shared")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{here}")
      (buffer-add-group! "#{first}" "#{shared}")
      (buffer-add-group! "#{second}" "#{here}")
      (set-frame-local! 'current-group "#{here}")
      (switch-to-buffer! "#{first}")
      (run-command "group-pop"))
    """)

    assert eval!(~s{(buffer-in-group? "#{first}" "#{here}")}) == "#f"
    assert eval!(~s{(buffer-in-group? "#{first}" "#{shared}")}) == "#t"
    assert eval!("(frame-local 'current-group)") == Jason.encode!(here)
    assert Editor.current_buffer() == second
    assert eval!(~s{(buffer-exists? "#{first}")}) == "#t"
  end

  test "C-x b puts the group's own members first and still switches", %{
    first: first,
    second: second,
    third: third
  } do
    id = group_id("current")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{id}")
      (buffer-add-group! "#{second}" "#{id}")
      (set-frame-local! 'current-group "#{id}")
      (switch-to-buffer! "#{first}"))
    """)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")

    labels = Editor.render_state().minibuffer.candidates |> Enum.map(& &1.label)

    # the member leads, under its heading; the stranger is present, below
    assert Enum.find_index(labels, &(&1 == second)) <
             Enum.find_index(labels, &(&1 == "other buffers"))

    # a stranger may sit below the rendered window: filter to prove it is
    # in the pool at all, then clear the filter again
    type(third)
    assert third in labels()
    for _ <- 1..String.length(third), do: KeyDispatch.handle_key("DEL")

    type(second)
    KeyDispatch.handle_key("RET")

    assert Editor.current_buffer() == second
    assert eval!("(frame-local 'current-group)") == Jason.encode!(id)
  end

  test "C-x b lists every buffer, the group's own under a heading first", %{
    first: first,
    second: second,
    third: third
  } do
    current_id = group_id("current")
    foreign_id = group_id("foreign")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{current_id}")
      (buffer-add-group! "#{second}" "#{current_id}")
      (buffer-add-group! "#{third}" "#{foreign_id}")
      (set-frame-local! 'current-group "#{current_id}")
      (switch-to-buffer! "#{first}"))
    """)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")

    labels = labels()

    # nothing is hidden: both sections are there, the group's own first
    assert "in this group" in labels
    assert "other buffers" in labels
    assert second in labels
    refute first in labels

    assert Enum.find_index(labels, &(&1 == "in this group")) <
             Enum.find_index(labels, &(&1 == second))

    assert Enum.find_index(labels, &(&1 == second)) <
             Enum.find_index(labels, &(&1 == "other buffers"))

    # the panel renders a WINDOW of rows, so a stranger can sit below the
    # fold: filter to it rather than asserting on what happens to show
    type(third)
    assert third in labels()
    assert Enum.find_index(labels(), &(&1 == "other buffers")) <
             Enum.find_index(labels(), &(&1 == third))

    KeyDispatch.handle_key("C-g")
  end

  test "a heading takes no selection and no count", %{
    first: first,
    second: second,
    third: third
  } do
    current_id = group_id("current")
    foreign_id = group_id("foreign")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{current_id}")
      (buffer-add-group! "#{second}" "#{current_id}")
      (buffer-add-group! "#{third}" "#{foreign_id}")
      (set-frame-local! 'current-group "#{current_id}")
      (switch-to-buffer! "#{first}"))
    """)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")

    # the first row selected is a real buffer, not the heading above it
    assert selected() == second

    # C-n steps OVER "other buffers": the row after the group's last member
    # is a real buffer, never the heading between them
    KeyDispatch.handle_key("C-n")
    after_heading = selected()
    assert after_heading != nil
    refute after_heading in ["in this group", "other buffers"]

    # and no number of steps can land on one
    for _ <- 1..8, do: KeyDispatch.handle_key("C-n")
    refute selected() in ["in this group", "other buffers"]

    KeyDispatch.handle_key("C-g")
  end

  test "a heading drops when the filter empties its section", %{
    first: first,
    second: second,
    third: third
  } do
    current_id = group_id("current")
    foreign_id = group_id("foreign")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{current_id}")
      (buffer-add-group! "#{second}" "#{current_id}")
      (buffer-add-group! "#{third}" "#{foreign_id}")
      (set-frame-local! 'current-group "#{current_id}")
      (switch-to-buffer! "#{first}"))
    """)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")

    # `third` lives only in the foreign group: filtering to it leaves the
    # group's own section empty, so its heading goes with it
    type(third)

    labels = Editor.render_state().minibuffer.candidates |> Enum.map(& &1.label)
    assert third in labels
    refute "in this group" in labels
    refute second in labels

    KeyDispatch.handle_key("C-g")
  end

  test "S-RET pulls the buffer into the current group instead of following it", %{
    first: first,
    second: second,
    third: third
  } do
    current_id = group_id("current")
    foreign_id = group_id("foreign")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{current_id}")
      (buffer-add-group! "#{second}" "#{current_id}")
      (buffer-add-group! "#{third}" "#{foreign_id}")
      (set-frame-local! 'current-group "#{current_id}")
      (switch-to-buffer! "#{first}"))
    """)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")
    type(third)
    KeyDispatch.handle_key("S-RET")

    # the buffer comes here; the context does not move to meet it
    assert Editor.current_buffer() == third
    assert eval!("(frame-local 'current-group)") == Jason.encode!(current_id)
    assert eval!(~s[(buffer-in-group? "#{third}" "#{current_id}")]) == "#t"
    # and it keeps the group it already had
    assert eval!(~s[(buffer-in-group? "#{third}" "#{foreign_id}")]) == "#t"
  end

  test "C-RET follows the buffer into its group and restores that layout", %{
    first: first,
    second: second,
    third: third
  } do
    current_id = group_id("current")
    foreign_id = group_id("foreign")

    # the foreign group remembers a layout that does NOT show `third`
    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{current_id}")
      (buffer-add-group! "#{second}" "#{foreign_id}")
      (buffer-add-group! "#{third}" "#{foreign_id}")
      (set-frame-local! 'current-group "#{foreign_id}")
      (delete-other-windows!)
      (switch-to-buffer! "#{second}")
      (group-layout-save! "#{foreign_id}")
      (set-frame-local! 'current-group "#{current_id}")
      (delete-other-windows!)
      (switch-to-buffer! "#{first}"))
    """)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")
    type(third)
    KeyDispatch.handle_key("C-RET")

    # the context follows the buffer, and the buffer is on screen even
    # though the saved layout never showed it
    assert eval!("(frame-local 'current-group)") == Jason.encode!(foreign_id)
    assert Editor.current_buffer() == third
    assert eval!(~s[(buffer-in-group? "#{third}" "#{current_id}")]) == "#f"
  end

  test "RET moves nothing but the window", %{first: first, second: second, third: third} do
    current_id = group_id("current")
    foreign_id = group_id("foreign")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{current_id}")
      (buffer-add-group! "#{second}" "#{current_id}")
      (buffer-add-group! "#{third}" "#{foreign_id}")
      (set-frame-local! 'current-group "#{current_id}")
      (switch-to-buffer! "#{first}"))
    """)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")
    type(third)
    KeyDispatch.handle_key("RET")

    assert Editor.current_buffer() == third
    assert eval!("(frame-local 'current-group)") == Jason.encode!(current_id)
    assert eval!(~s[(buffer-in-group? "#{third}" "#{current_id}")]) == "#f"
  end

  test "C-x g changes context and restores the saved layout", %{
    first: first,
    second: second
  } do
    left = group_id("left")
    right = group_id("right")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{left}")
      (buffer-add-group! "#{second}" "#{right}")
      (set-frame-local! 'current-group "#{right}")
      (switch-to-buffer! "#{second}")
      (group-layout-save! "#{right}")
      (set-frame-local! 'current-group "#{left}")
      (switch-to-buffer! "#{first}"))
    """)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("g")
    type("right")
    KeyDispatch.handle_key("RET")

    assert Editor.current_buffer() == second
    assert eval!("(frame-local 'current-group)") == Jason.encode!(right)
    assert eval!("(frame-local 'previous-group)") == Jason.encode!(left)
    assert eval!(~s{(buffer-group "#{first}")}) == Jason.encode!(left)
  end

end
