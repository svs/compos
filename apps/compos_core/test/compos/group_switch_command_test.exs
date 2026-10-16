defmodule Compos.GroupSwitchCommandTest do
  @moduledoc """
  Group integration at the Elixir/Scheme rendering and command boundary.

  The switcher is Scheme and its tests are Scheme —
  priv/tests/group-switch-test.scm covers group creation, add, move,
  remove, buffer switching, and layout restore.

  This one was red in every baseline, and it was the test that was
  wrong: it opened ibuffer and pressed the switcher's chords at it.
  ibuffer was this same list from edb89bf until 584f308 gave the
  traditional table back.
  """

  use ExUnit.Case

  alias Compos.Core.{Editor, KeyDispatch, Session}
  alias Compos.Core.Events

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

  defp leaves(%{type: :leaf} = leaf), do: [leaf]
  defp leaves(%{type: :split, children: children}), do: Enum.flat_map(children, &leaves/1)

  setup do
    Editor.set_pending([])
    Session.eval("(when (minibuffer-state) (minibuffer-cancel!))")

    n = System.unique_integer([:positive])
    first = "groups-first-#{n}"
    second = "groups-second-#{n}"
    third = "groups-third-#{n}"

    for buffer <- [first, second, third], do: Compos.Core.create_buffer(buffer)

    eval!("""
    (begin
      (set! *group-records* '())
      (set! *group-next-id* 0)
      (set-frame-local! 'current-group #f)
      (set-frame-local! 'previous-group #f)
      (set-frame-local! 'pinned-group #f)
      (frame-group-label-refresh!)
      (delete-other-windows!)
      (switch-to-buffer! "#{first}"))
    """)

    on_exit(fn ->
      for buffer <- [first, second, third], do: Compos.Core.kill_buffer(buffer)

      Session.eval("""
      (begin
        (set! *group-records* '())
        (set! *group-next-id* 0)
        (set-frame-local! 'current-group #f)
        (set-frame-local! 'previous-group #f)
        (set-frame-local! 'pinned-group #f)
        (frame-group-label-refresh!)
        (delete-other-windows!))
      """)
    end)

    %{first: first, second: second, third: third}
  end

  test "a move shows what it moved, not the destination as it was", %{
    first: first,
    second: second
  } do
    # The destination's saved layout was made before the buffer joined it, so
    # entering the group drew it as it was: you moved a buffer somewhere and
    # landed looking at everything except it.
    destination = group_id("move-show-dest-#{System.unique_integer([:positive])}")

    eval!(~s{(buffer-add-group! "#{second}" "#{destination}")})
    eval!(~s{(switch-to-group! "#{destination}")})
    eval!(~s{(switch-to-buffer-here! "#{second}")})
    eval!(~s{(group-layout-save! (group-resolve-id "#{destination}"))})

    eval!(~s{(switch-to-buffer! "#{first}")})
    eval!(~s{(group-move-buffers-to! (list "#{first}") "#{destination}")})

    assert eval!("(layout-visible-buffers)") =~ first,
           "the moved buffer is not on screen in the group it moved to"

    assert eval!("(current-buffer)") == ~s("#{first}")
  end

  test "a move refreshes visible headlines and catches up hidden ones when shown", %{
    first: first,
    second: second
  } do
    # post-command! syncs the buffer the command ran in and no other, so a
    # move that takes several buffers left the rest drawing the group they
    # had just left. Only the current one caught up.
    source = group_id("headline-source-#{System.unique_integer([:positive])}")
    destination = group_id("headline-dest-#{System.unique_integer([:positive])}")

    eval!(~s{(buffer-add-group! "#{first}" "#{source}")})
    eval!(~s{(buffer-add-group! "#{second}" "#{source}")})
    eval!(~s{(switch-to-buffer! "#{first}")})

    # a real command, so the headline exists to go stale in the first place
    Session.run_command("beginning-of-buffer")

    eval!(
      ~s{(define-command "zz-headline-move"
               (lambda () (group-move-buffers-to! (list "#{first}" "#{second}") "#{destination}")))}
    )

    Session.run_command("zz-headline-move")

    for buffer <- [first, second] do
      assert eval!(~s{(group-label (dashboard--group "#{buffer}"))}) =~ "headline-dest",
             "#{buffer} did not move"

      unless Enum.any?(leaves(Editor.render_state().tree), &(&1.buffer == buffer)) do
        assert eval!(~s{(buffer-local "#{buffer}" 'group-display-dirty)}) == "#t"
        Editor.set_window_buffer(buffer)
        eval!("(windows-shown-catchup!)")
      end

      assert eval!(~s{(equal? (buffer-local "#{buffer}" 'dashboard-line-blocks)
                          (dashboard-line-blocks "#{buffer}"))}) == "#t",
             "#{buffer} kept a headline from before the move"
    end
  end

  test "grouped filenames carry their group face in minibuffer candidates", %{
    first: first,
    second: second
  } do
    here = group_id("filename-face")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{here}")
      (buffer-add-group! "#{second}" "#{here}")
      (set-frame-local! 'current-group "#{here}")
      (frame-group-label-refresh!)
      (switch-to-buffer! "#{first}")
      (run-command "ibuffer-prompt"))
    """)

    expected = eval!(~s[(group-color-face "#{here}")]) |> Jason.decode!()
    candidate = Enum.find(Editor.render_state().minibuffer.candidates, &(&1.label == second))

    assert candidate.face == expected
  end

  test "C-x C-g runs find-file-in-new-group" do
    eval!(~s{(global-set-key "C-x C-g" "find-file-in-new-group")})
    eval!("(group-keymap-install!)")

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("C-g")

    assert Editor.render_state().minibuffer.prompt == "Find file in new group: "
  end

  test "a pinned group uses the pin icon in frame and buffer labels", %{first: first} do
    pinned = group_id("pinned-label")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{pinned}")
      (set-frame-local! 'current-group "#{pinned}")
      (switch-to-buffer! "#{first}")
      (run-command "group-pin")
      (post-command!))
    """)

    rendered = Editor.render_state()

    assert rendered.frame_group == "pinned-label "
    assert eval!(~s[(group-label "#{pinned}")]) == Jason.encode!("pinned-label ")

    blocks = Compos.Core.Buffer.get_local(first, "dashboard-line-blocks") |> inspect()
    assert blocks =~ "pinned-label "
  end

  test "group switch candidates name buffers with project and home abbreviations" do
    n = System.unique_integer([:positive])
    test_home = eval!("(compos-home)") |> Jason.decode!()
    home = eval!(~s[(getenv "HOME")]) |> Jason.decode!()
    root = Path.join(test_home, "zz-switch-project-#{n}")
    project_file = Path.join(root, "lib/code.scm")
    home_buffer = Path.join(home, "zz-switch-home-#{n}.scm")

    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(Path.dirname(project_file))
    File.write!(project_file, "project")
    Compos.Core.create_buffer(home_buffer)

    on_exit(fn ->
      Session.eval(
        ~s{(begin (buffer-kill! #{Jason.encode!(project_file)}) (buffer-kill! #{Jason.encode!(home_buffer)}))}
      )

      File.rm_rf!(root)
    end)

    group = group_id("switch-marginalia")

    # the switcher's row names the group and counts it; its facts name no
    # member
    [hint, kind, facts] =
      eval!("""
      (begin
        (visit #{Jason.encode!(project_file)})
        (buffer-add-group! #{Jason.encode!(project_file)} "#{group}")
        (buffer-add-group! #{Jason.encode!(home_buffer)} "#{group}")
        (let ((row (group-switch-candidate "#{group}")))
          (string-join
            (list (cadr row) (nth 2 row)
                  (string-join (map (lambda (f) (cadr f)) (nth 5 row)) " · "))
            " | ")))
      """)
      |> Jason.decode!()
      |> String.split(" | ")

    assert hint == "2 buffers"
    assert kind == "container"

    refute facts =~ "lib/code.scm"
    refute facts =~ "zz-switch-home-#{n}.scm"
  end

  test "a new group record schedules desktop persistence" do
    :ok = Events.subscribe_editor()
    name = "persisted-group-#{System.unique_integer([:positive])}"

    group_id(name)

    assert_receive {:editor_change, :scheme_state}
  end

  test "remove-group-from-buffer asks before it removes, and y removes", %{first: first} do
    remove = group_id("remove-on-close")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{remove}")
      (switch-to-buffer! "#{first}")
      (run-command "remove-group-from-buffer"))
    """)

    assert Editor.render_state().minibuffer.prompt =~ ~r/^Remove /
    assert eval!(~s[(buffer-in-group? "#{first}" "#{remove}")]) == "#t"

    KeyDispatch.handle_key("y")
    assert eval!(~s[(buffer-in-group? "#{first}" "#{remove}")]) == "#f"
    assert eval!(~s[(buffer-group "#{first}")]) == "#f"
    assert Editor.render_state().minibuffer == nil
  end

  test "remove-group-from-buffer answered n keeps the group", %{first: first} do
    only = group_id("remove-only-on-close")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{only}")
      (switch-to-buffer! "#{first}")
      (run-command "remove-group-from-buffer"))
    """)

    assert Editor.render_state().minibuffer.prompt =~ ~r/^Remove /
    KeyDispatch.handle_key("n")
    assert eval!(~s[(buffer-in-group? "#{first}" "#{only}")]) == "#t"
    assert Editor.render_state().minibuffer == nil
  end

  test "group-add changes selected buffers only", %{
    first: first,
    second: second,
    third: third
  } do
    destination = group_id("selected-add")

    # no default group: the frame stands in none and left none
    eval!("""
    (begin
      (set-frame-local! 'current-group #f)
      (set-frame-local! 'previous-group #f)
      (buffer-set-local! "#{first}" 'buffer-selected #t)
      (buffer-set-local! "#{second}" 'buffer-selected #t)
      (switch-to-buffer! "#{third}")
      (run-command "group-add")
      (minibuffer-change! "selected-add"))
    """)

    # the prompt may name a default (the most recent group); the typed
    # name wins over it
    assert Editor.render_state().minibuffer.prompt =~ ~r/^Put buffers in group/
    KeyDispatch.handle_key("RET")

    assert eval!(~s[(buffer-in-group? "#{first}" "#{destination}")]) == "#t"
    assert eval!(~s[(buffer-in-group? "#{second}" "#{destination}")]) == "#t"
    assert eval!(~s[(buffer-in-group? "#{third}" "#{destination}")]) == "#f"
    assert eval!(~s[(buffer-local "#{first}" 'buffer-selected)]) == "#f"
    assert eval!(~s[(buffer-local "#{second}" 'buffer-selected)]) == "#f"
  end

  test "a homogeneous buffer supplies both its buffer and frame color", %{
    first: first,
    second: second
  } do
    mail = group_id("color-mail")
    docs = group_id("color-docs")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{mail}")
      (buffer-add-group! "#{second}" "#{docs}")
      (set-frame-local! 'current-group "#{mail}")
      (frame-group-label-refresh!)
      ;; the pane takes the other group's buffer as a layout would: a
      ;; switch would float it in the popup (sealed groups)
      (switch-to-buffer-here! "#{second}"))
    """)

    rendered = Editor.render_state()
    leaf = rendered.tree |> leaves() |> Enum.find(&(&1.buffer == second))

    docs_color =
      eval!(~s[(group-color-hex (group-record-color (group-record-by-id "#{docs}")))])
      |> Jason.decode!()

    mail_color =
      eval!(~s[(group-color-hex (group-record-color (group-record-by-id "#{mail}")))])
      |> Jason.decode!()

    docs_face = eval!(~s[(group-color-face "#{docs}")]) |> Jason.decode!()

    assert rendered.frame_group == "color-docs"
    assert leaf.group_color == docs_color
    refute leaf.group_color == mail_color
    assert eval!(~s[(buffer-filename-face "#{second}")]) == Jason.encode!(docs_face)
  end

  test "modelines pin this buffer's group when it is not the frame's", %{
    first: first,
    second: second,
    third: third
  } do
    here = group_id("modeline-here")
    other = group_id("modeline-other")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{other}")
      (buffer-add-group! "#{second}" "#{other}")
      (buffer-add-group! "#{third}" "#{here}")
      (delete-other-windows!)
      ;; the panes take buffers of other groups as a layout would
      (switch-to-buffer-here! "#{first}")
      (split-window! 'h)
      (other-window!)
      (switch-to-buffer-here! "#{second}")
      (split-window! 'v)
      (other-window!)
      (switch-to-buffer-here! "#{third}")
      (set-frame-local! 'current-group "#{here}")
      (frame-group-label-refresh!))
    """)

    rendered = Editor.render_state()
    by_buffer = rendered.tree |> leaves() |> Map.new(&{&1.buffer, &1})

    # a pane in another group wears that group's color; one in the frame's wears none
    other_color =
      eval!(~s[(group-color-hex (group-record-color (group-record-by-id "#{other}")))])
      |> Jason.decode!()

    assert by_buffer[first].group_color == other_color
    assert by_buffer[second].group_color == other_color
    assert rendered.frame_group == "modeline-here"
    assert rendered.frame_group_color =~ ~r/^#[0-9a-f]{6}$/i

    # C-x ? is the expanded view: it names the buffer's one group.
    eval!(~s{(select-window! (window-showing "#{first}"))})
    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("?")

    blocks =
      first
      |> Compos.Core.Buffer.get_local("modeline-dash-blocks")
      |> inspect(limit: :infinity, printable_limit: :infinity)

    assert blocks =~ "modeline-other"
    refute blocks =~ "modeline-here"

    # No group is genuinely ungrouped even while the frame stays here.
    eval!(~s{(buffer-move-to-group! "#{third}" #f)})
    by_buffer = Editor.render_state().tree |> leaves() |> Map.new(&{&1.buffer, &1})
    refute by_buffer[third].group_color
  end
end
