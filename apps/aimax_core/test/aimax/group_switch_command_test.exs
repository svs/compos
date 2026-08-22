defmodule Aimax.GroupSwitchCommandTest do
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

  test "rename keeps a stable group ID", %{first: buffer} do
    id = group_id("stable")
    eval!(~s{(buffer-add-group! "#{buffer}" "#{id}")})

    eval!(~s{(group-rename! "#{id}" "renamed")})

    assert eval!(~s{(buffer-group "#{buffer}")}) == Jason.encode!(id)
    assert eval!(~s{(group-name "#{id}")}) == ~s{"renamed"}
  end

  test "work buffers keep unique group ID sets", %{first: buffer} do
    left = group_id("left")
    right = group_id("right")

    result =
      eval!("""
      (begin
        (buffer-add-group! "#{buffer}" "#{left}")
        (buffer-add-group! "#{buffer}" "#{left}")
        (buffer-add-group! "#{buffer}" "#{right}")
        (buffer-remove-group! "#{buffer}" "#{left}")
        (list (buffer-in-group? "#{buffer}" "#{left}")
              (buffer-in-group? "#{buffer}" "#{right}")
              (length (buffer-group-ids "#{buffer}"))))
      """)

    assert result == "(#f #t 1)"
  end

  test "legacy names migrate once to stable IDs", %{first: work} do
    chat = "*chat:legacy*"
    Aimax.Core.create_buffer(chat)

    on_exit(fn -> Aimax.Core.kill_buffer(chat) end)

    result =
      eval!("""
      (begin
        (buffer-set-local! "#{work}" 'group "legacy")
        (buffer-set-local! "#{chat}" 'group "legacy")
        (with-current-buffer "#{chat}" (lambda () (set-mode! "chat-mode")))
        (let ((work-id (buffer-group "#{work}"))
              (chat-id (chat-group-id "#{chat}")))
          (list (equal? work-id chat-id)
                (length (group-ids))
                (length (buffer-group-ids "#{work}"))
                (length (buffer-group-ids "#{chat}")))))
      """)

    assert result == "(#t 1 1 0)"
  end

  test "empty group records remain durable" do
    id = group_id("empty")

    assert eval!(~s{(group-name "#{id}")}) == ~s{"empty"}
    assert eval!(~s{(length (group-buffers "#{id}"))}) == "0"
    assert eval!("(if (assoc 'groups-v2 (desktop-globals)) #t #f)") == "#t"
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

  test "a chat clears a group id whose record is gone", %{first: first} do
    gone = group_id("gone")
    chat = "*chat:dangling-#{System.unique_integer([:positive])}*"
    Aimax.Core.create_buffer(chat)
    on_exit(fn -> Aimax.Core.kill_buffer(chat) end)

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{gone}")
      (buffer-set-local! "#{chat}" 'group-id "#{gone}")
      (buffer-set-local! "#{chat}" 'mode-name "chat-mode"))
    """)

    assert eval!(~s[(chat-group-id "#{chat}")]) == Jason.encode!(gone)

    # the record goes while the chat is not swept (asleep, or deleted
    # straight from the board): the id it holds now names nothing
    eval!(~s{(group-record-delete! "#{gone}")})

    # reading it heals it, rather than handing back a dead id forever
    assert eval!(~s[(chat-group-id "#{chat}")]) == "#f"
    assert eval!(~s[(buffer-local "#{chat}" 'group-id)]) == "#f"
    assert eval!(~s[(buffer-group-summary "#{chat}")]) == ~s{"ungrouped"}
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

  test "a group can own many chats and one primary chat" do
    id = group_id("chat-owner")

    on_exit(fn ->
      Aimax.Core.kill_buffer("*chat:chat-owner*")
      Aimax.Core.kill_buffer("*chat:chat-owner:2*")
    end)

    result =
      eval!("""
      (let* ((first (group-chat "#{id}"))
             (second (group-chat-new! "#{id}")))
        (list (not (equal? first second))
              (equal? (chat-group-id first) "#{id}")
              (equal? (chat-group-id second) "#{id}")
              (equal? (group-primary-chat "#{id}") second)
              (length (buffer-group-ids first))
              (length (filter chat-buffer? (group-buffers "#{id}")))))
      """)

    assert result == "(#t #t #t #t 0 2)"
  end

  test "dissolve keeps buffers and their other memberships", %{first: first} do
    dissolved = group_id("dissolved")
    kept = group_id("kept")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{dissolved}")
      (buffer-add-group! "#{first}" "#{kept}")
      (group-dissolve! "#{dissolved}"))
    """)

    assert eval!(~s{(buffer-exists? "#{first}")}) == "#t"
    assert eval!(~s{(buffer-group-ids "#{first}")}) == ~s{("#{kept}")}
    assert eval!(~s{(group-resolve-id "#{dissolved}")}) == "#f"
  end

  test "remembered layouts are keyed by frame", %{first: first} do
    id = group_id("layout")

    result =
      eval!("""
      (begin
        (buffer-add-group! "#{first}" "#{id}")
        (switch-to-buffer! "#{first}")
        (group-layout-save! "#{id}")
        (let ((saved (group-record-layout (group-record-by-id "#{id}"))))
          (list (equal? (car saved) 'per-frame)
                (equal? (car (car (cdr saved))) (selected-frame))
                (equal? (group-layout "#{id}") (window-tree)))))
      """)

    assert result == "(#t #t #t)"
  end


  test "frame group context restores stable IDs without runtime locals" do
    current = group_id("frame-current")
    previous = group_id("frame-previous")

    restored =
      eval!("""
      (begin
        (set-frame-local! 'current-group "#{current}")
        (set-frame-local! 'previous-group "#{previous}")
        (set-frame-local! 'winner-pos 7)
        (let ((saved (group-frame-context-state)))
          (set-frame-local! 'current-group #f)
          (set-frame-local! 'previous-group #f)
          (group-frame-context-restore! saved)
          (list (frame-local 'current-group)
                (frame-local 'previous-group)
                (frame-local 'winner-pos))))
      """)

    assert restored == ~s{("#{current}" "#{previous}" 7)}

    malformed =
      eval!("""
      (begin
        (group-frame-context-restore!
          (list 'bad
                (list (selected-frame)
                      (list (list 'current-group)
                            (list 'current-group 42)
                            (list 'previous-group "#{previous}")))))
        (list (frame-local 'current-group)
              (frame-local 'previous-group)
              (frame-local 'winner-pos)))
      """)

    assert malformed == ~s{(#f "#{previous}" 7)}

    deleted = group_id("frame-deleted")

    cleared =
      eval!("""
      (begin
        (set-frame-local! 'current-group "#{deleted}")
        (set-frame-local! 'previous-group "#{deleted}")
        (group-record-delete! "#{deleted}")
        (list (frame-local 'current-group)
              (frame-local 'previous-group)
              (frame-local 'winner-pos)))
      """)

    assert cleared == "(#f #f 7)"

  end

  test "invalid noise normalizes to quiet" do
    id = group_id("noise")

    eval!(~s{(group-noise-set! "#{id}" "unknown")})

    assert eval!(~s{(group-noise "#{id}")}) == ~s{"quiet"}
  end
end
