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
      (run-command "group-switch-buffer"))
    """)

    expected = eval!(~s[(group-color-face "#{here}")]) |> Jason.decode!()
    candidate = Enum.find(Editor.render_state().minibuffer.candidates, &(&1.label == second))

    assert candidate.face == expected
  end

  test "C-x C-g opens the group menu and f finds a file for a new group" do
    eval!(~s{(global-set-key "C-x C-g" "find-file-in-new-group")})
    eval!("(group-keymap-install!)")

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("C-g")

    assert Editor.snapshot().pending == ["C-x", "C-g"]
    assert Enum.any?(Editor.render_state().which_key, &(&1.key == "f"))

    KeyDispatch.handle_key("f")
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
    leaf = rendered.tree |> leaves() |> Enum.find(&(&1.buffer == first))

    assert rendered.frame_group == "pinned-label "
    assert leaf.group == "pinned-label "
    assert eval!(~s[(group-label "#{pinned}")]) == Jason.encode!("pinned-label ")

    blocks = Compos.Core.Buffer.get_local(first, "dashboard-line-blocks") |> inspect()
    assert blocks =~ "pinned-label "
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

    hint =
      eval!("""
      (begin
        (visit #{Jason.encode!(project_file)})
        (buffer-add-group! #{Jason.encode!(project_file)} "#{group}")
        (buffer-add-group! #{Jason.encode!(home_buffer)} "#{group}")
        (cadr (group-switch-candidate "#{group}")))
      """)
      |> Jason.decode!()

    assert hint =~ "lib/code.scm"
    assert hint =~ "~/zz-switch-home-#{n}.scm"
    refute hint =~ root
    refute hint =~ home_buffer
  end

  test "a new group record schedules desktop persistence" do
    :ok = Events.subscribe_editor()
    name = "persisted-group-#{System.unique_integer([:positive])}"

    group_id(name)

    assert_receive {:editor_change, :scheme_state}
  end

  test "buffer-remove-from-group applies pending removals on C-g", %{first: first} do
    remove = group_id("remove-on-close")
    keep = group_id("keep-on-close")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{remove}")
      (buffer-add-group! "#{first}" "#{keep}")
      (switch-to-buffer! "#{first}")
      (run-command "remove-group-from-buffer")
      (minibuffer-change! "remove-on-close"))
    """)

    assert Editor.render_state().minibuffer.prompt == "Toggle group removal (C-g applies): "

    KeyDispatch.handle_key("RET")
    assert eval!(~s[(buffer-in-group? "#{first}" "#{remove}")]) == "#t"
    assert Editor.render_state().minibuffer.prompt == "Toggle group removal (C-g applies): "

    KeyDispatch.handle_key("C-g")
    assert eval!(~s[(buffer-in-group? "#{first}" "#{remove}")]) == "#f"
    assert eval!(~s[(buffer-in-group? "#{first}" "#{keep}")]) == "#t"
    assert Editor.render_state().minibuffer == nil
  end

  test "remove-group-from-buffer stages the only membership before C-g applies it", %{first: first} do
    only = group_id("remove-only-on-close")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{only}")
      (switch-to-buffer! "#{first}")
      (run-command "remove-group-from-buffer"))
    """)

    assert Editor.render_state().minibuffer.prompt == "Toggle group removal (C-g applies): "
    assert eval!(~s[(buffer-in-group? "#{first}" "#{only}")]) == "#t"

    eval!(~s[(minibuffer-change! "remove-only-on-close")])
    KeyDispatch.handle_key("RET")
    assert eval!(~s[(buffer-in-group? "#{first}" "#{only}")]) == "#t"

    KeyDispatch.handle_key("C-g")
    assert eval!(~s[(buffer-in-group? "#{first}" "#{only}")]) == "#f"
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
    assert Editor.render_state().minibuffer.prompt =~ ~r/^Add buffers to group/
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
      (switch-to-buffer! "#{second}"))
    """)

    rendered = Editor.render_state()
    leaf = rendered.tree |> leaves() |> Enum.find(&(&1.buffer == second))
    docs_color = eval!(~s[(group-record-color (group-record-by-id "#{docs}"))]) |> Jason.decode!()
    mail_color = eval!(~s[(group-record-color (group-record-by-id "#{mail}"))]) |> Jason.decode!()
    docs_face = eval!(~s[(group-color-face "#{docs}")]) |> Jason.decode!()

    assert rendered.frame_group == "color-docs"
    assert leaf.group == "color-docs"
    assert leaf.group_color == docs_color
    refute leaf.group_color == mail_color
    assert eval!(~s[(buffer-filename-face "#{second}")]) == Jason.encode!(docs_face)
  end

  test "modelines compact this buffer's memberships relative to the frame group", %{
    first: first,
    second: second,
    third: third
  } do
    here = group_id("modeline-here")
    other = group_id("modeline-other")
    extra = group_id("modeline-extra")

    eval!("""
    (begin
      (buffer-add-group! "#{first}" "#{here}")
      (buffer-add-group! "#{first}" "#{other}")
      (buffer-add-group! "#{first}" "#{extra}")
      (buffer-add-group! "#{second}" "#{other}")
      (buffer-add-group! "#{second}" "#{extra}")
      (buffer-add-group! "#{third}" "#{other}")
      (set-frame-local! 'current-group "#{here}")
      (frame-group-label-refresh!)
      (delete-other-windows!)
      (switch-to-buffer! "#{first}")
      (split-window! 'h)
      (other-window!)
      (switch-to-buffer! "#{second}")
      (split-window! 'v)
      (other-window!)
      (switch-to-buffer! "#{third}"))
    """)

    rendered = Editor.render_state()
    by_buffer = rendered.tree |> leaves() |> Map.new(&{&1.buffer, &1})

    assert by_buffer[first].group == "modeline-other (2 more)"
    assert by_buffer[second].group == "modeline-other (1 more)"
    assert by_buffer[third].group == "modeline-other"
    assert rendered.frame_group == "modeline-other"
    assert rendered.frame_group_color =~ ~r/^#[0-9a-f]{6}$/i

    # C-x ? is the expanded, lossless view: it names every membership.
    eval!(~s{(select-window! (window-showing "#{first}"))})
    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("?")

    blocks =
      first
      |> Compos.Core.Buffer.get_local("modeline-dash-blocks")
      |> inspect(limit: :infinity, printable_limit: :infinity)

    assert blocks =~ "modeline-here"
    assert blocks =~ "modeline-other"
    assert blocks =~ "modeline-extra"

    # Zero memberships is genuinely ungrouped even while the frame stays here.
    eval!(~s{(buffer-move-to-group! "#{third}" #f)})
    by_buffer = Editor.render_state().tree |> leaves() |> Map.new(&{&1.buffer, &1})
    assert by_buffer[third].group == nil
  end
end
