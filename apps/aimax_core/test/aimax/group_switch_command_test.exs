defmodule Aimax.GroupSwitchCommandTest do
  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp type(text) do
    text
    |> String.graphemes()
    |> Enum.each(&KeyDispatch.handle_key/1)
  end

  setup do
    n = System.unique_integer([:positive])
    first = "group-switch-first-#{n}"
    second = "group-switch-second-#{n}"
    group = "group-switch-#{n}"

    for buffer <- [first, second], do: Aimax.Core.create_buffer(buffer)

    on_exit(fn ->
      for buffer <- [
            first,
            second,
            "*chat:#{group}*",
            "*chat:#{group}:2*",
            "*chat:#{group}:3*",
            "*chat:#{group}-added*"
          ],
          do: Aimax.Core.kill_buffer(buffer)

      {:ok, _} = Session.eval("(set-frame-local! 'current-group #f)")
      Editor.delete_other_windows()
    end)

    %{first: first, second: second, group: group}
  end

  test "C-c G restores the current buffer's group layout", context do
    %{first: first, second: second, group: group} = context

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "#{group}")
        (buffer-set-local! "#{second}" 'group "#{group}")
        (delete-other-windows!)
        (switch-to-buffer! "#{first}")
        (split-window! 'h 0.5)
        (other-window!)
        (switch-to-buffer! "#{second}")
        (group-layout-save! "#{group}")
        (delete-other-windows!)
        (switch-to-buffer! "#{first}"))
      """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("G")

    shown = Editor.list_windows() |> Enum.map(fn {_id, buffer} -> buffer end) |> Enum.sort()

    assert shown == Enum.sort([first, second])
    assert Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{group}"}}
  end

  test "C-c G leaves an ungrouped buffer in place", context do
    %{first: first} = context

    {:ok, _} = Session.eval(~s{(begin (delete-other-windows!) (switch-to-buffer! "#{first}"))})

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("G")

    assert Editor.current_buffer() == first
    assert Buffer.text("*messages*") =~ "Not in a group"
  end

  test "C-x C-g g selects the active group and restores its layout", context do
    %{first: first, second: second, group: group} = context
    source = "source-#{group}"

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "#{source}")
        (buffer-set-local! "#{second}" 'group "#{group}")
        (delete-other-windows!)
        (switch-to-buffer! "#{second}")
        (group-layout-save! "#{group}")
        (switch-to-buffer! "#{first}")
        (set-frame-local! 'current-group "#{source}"))
      """)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("C-g")
    KeyDispatch.handle_key("g")

    assert Editor.render_state().minibuffer.prompt == "Switch to group: "
    assert Enum.any?(Editor.render_state().minibuffer.candidates, &(&1.label == group))

    type(group)
    KeyDispatch.handle_key("RET")

    assert Editor.current_buffer() == second
    assert Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{group}"}}
  end

  test "the groups board uses group-switch without exposing an internal command", context do
    %{first: first, group: group} = context

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "#{group}")
        (switch-to-buffer! "#{first}")
        (group-layout-save! "#{group}")
        (run-command "groups"))
      """)

    assert Session.eval(~s{(groups--current)}) == {:ok, ~s{"#{group}"}}
    assert Session.eval(~s{(if (member "group-switch-at-point" (command-names)) #t #f)}) ==
             {:ok, "#f"}

    KeyDispatch.handle_key("RET")

    assert Editor.current_buffer() == first
    assert Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{group}"}}
  end

  test "C-c N founds a new group from every visible buffer", context do
    %{first: first, second: second, group: group} = context

    {:ok, _} =
      Session.eval("""
      (begin
        (delete-other-windows!)
        (switch-to-buffer! "#{first}")
        (split-window! 'h 0.5)
        (other-window!)
        (switch-to-buffer! "#{second}"))
      """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("N")
    type(group)
    KeyDispatch.handle_key("RET")

    assert Session.eval(~s{(buffer-group "#{first}")}) == {:ok, ~s{"#{group}"}}
    assert Session.eval(~s{(buffer-group "#{second}")}) == {:ok, ~s{"#{group}"}}
    assert Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{group}"}}
    assert Session.eval(~s{(equal? (group-layout "#{group}") (window-tree))}) == {:ok, "#t"}
  end

  test "C-c N moves visible buffers to an existing group", context do
    %{first: first, second: second, group: group} = context

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "source-#{group}")
        (buffer-add-group! "#{first}" "extra-#{group}")
        (buffer-set-local! "#{second}" 'group "#{group}")
        (delete-other-windows!)
        (switch-to-buffer! "#{first}"))
      """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("N")

    assert Enum.any?(Editor.render_state().minibuffer.candidates, &(&1.label == group))

    type(group)
    KeyDispatch.handle_key("RET")

    assert Session.eval(~s{(buffer-group "#{first}")}) == {:ok, ~s{"#{group}"}}
    assert Session.eval(~s{(buffer-groups "#{first}")}) == {:ok, ~s{("#{group}")}}
    assert Session.eval(~s{(buffer-group "#{second}")}) == {:ok, ~s{"#{group}"}}
    assert Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{group}"}}
    assert Session.eval(~s{(equal? (group-layout "#{group}") (window-tree))}) == {:ok, "#t"}
    assert Buffer.text("*messages*") =~ "visible buffers to group #{group}"
  end

  test "C-c A adds an existing group without replacing membership or layout", context do
    %{first: first, second: second, group: group} = context
    source = "source-#{group}"

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "#{source}")
        (buffer-set-local! "#{second}" 'group "#{group}")
        (delete-other-windows!)
        (switch-to-buffer! "#{second}")
        (group-layout-save! "#{group}")
        (switch-to-buffer! "#{first}")
        (set-frame-local! 'current-group "#{source}"))
      """)

    {:ok, saved_layout} = Session.eval(~s{(group-layout "#{group}")})

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("A")
    type(group)
    KeyDispatch.handle_key("RET")

    assert Session.eval(~s{(buffer-group "#{first}")}) == {:ok, ~s{"#{source}"}}

    assert Session.eval(~s{(buffer-groups "#{first}")}) ==
             {:ok, ~s{("#{source}" "#{group}")}}

    assert Session.eval(~s{(buffer-in-group? "#{first}" "#{group}")}) == {:ok, "#t"}

    assert Session.eval(~s{(if (member "#{first}" (group-buffers "#{group}")) #t #f)}) ==
             {:ok, "#t"}

    assert Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{source}"}}
    assert Session.eval(~s{(group-layout "#{group}")}) == {:ok, saved_layout}
  end

  test "group-add adds a selected group to only the current buffer", context do
    %{first: first, second: second, group: group} = context
    source = "source-#{group}"

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "#{source}")
        (buffer-set-local! "#{second}" 'group "#{group}")
        (delete-other-windows!)
        (switch-to-buffer! "#{first}")
        (run-command "group-add"))
      """)

    type(group)
    KeyDispatch.handle_key("RET")

    assert Session.eval(~s{(buffer-groups "#{first}")}) ==
             {:ok, ~s{("#{source}" "#{group}")}}

    assert Session.eval(~s{(buffer-groups "#{second}")}) == {:ok, ~s{("#{group}")}}
  end

  test "group-add founds a new additional membership", context do
    %{first: first, group: group} = context
    added = "#{group}-added"

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "#{group}")
        (switch-to-buffer! "#{first}")
        (run-command "group-add"))
      """)

    type(added)
    KeyDispatch.handle_key("RET")

    assert Session.eval(~s{(buffer-groups "#{first}")}) ==
             {:ok, ~s{("#{group}" "#{added}")}}
  end

  test "group-move replaces every membership of only the current buffer", context do
    %{first: first, second: second, group: group} = context
    source = "source-#{group}"

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "#{source}")
        (buffer-add-group! "#{first}" "extra-#{group}")
        (buffer-set-local! "#{second}" 'group "#{group}")
        (buffer-add-group! "#{second}" "stay-#{group}")
        (delete-other-windows!)
        (switch-to-buffer! "#{first}")
        (run-command "group-move"))
      """)

    type(group)
    KeyDispatch.handle_key("RET")

    assert Session.eval(~s{(buffer-groups "#{first}")}) == {:ok, ~s{("#{group}")}}

    assert Session.eval(~s{(buffer-groups "#{second}")}) ==
             {:ok, ~s{("#{group}" "stay-#{group}")}}
  end

  test "C-x C-g exposes the group convenience map" do
    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("C-g")

    bindings = Editor.render_state().which_key

    assert %{key: "s", command: "switch-groups"} in bindings
    assert %{key: "g", command: "group-switch"} in bindings
    assert %{key: "f", command: "group-find-file"} in bindings
    assert %{key: "a", command: "group-add"} in bindings
    assert %{key: "m", command: "group-move"} in bindings
    assert %{key: "A", command: "group-add-visible"} in bindings
    assert %{key: "M", command: "group-move-visible"} in bindings
    assert %{key: "l", command: "group-list"} in bindings

    KeyDispatch.handle_key("C-g")
  end

  test "group-find-file adds the active secondary group to an existing file", context do
    %{first: first, group: group} = context
    primary = "primary-#{group}"
    existing = "existing-#{group}"
    path = Path.join(System.tmp_dir!(), "group-find-file-#{group}.txt")
    File.write!(path, "group file\n")

    on_exit(fn ->
      Aimax.Core.kill_buffer(path)
      File.rm(path)
    end)

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "#{primary}")
        (buffer-add-group! "#{first}" "#{group}")
        (find-file "#{path}")
        (buffer-set-local! "#{path}" 'group "#{existing}")
        (switch-to-buffer! "#{first}")
        (set-frame-local! 'current-group "#{group}"))
      """)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("C-g")
    KeyDispatch.handle_key("f")
    type(path)
    KeyDispatch.handle_key("RET")

    assert Editor.current_buffer() == path

    assert Session.eval(~s{(buffer-groups "#{path}")}) ==
             {:ok, ~s{("#{existing}" "#{group}")}}
  end

  test "C-c A founds an additional group without leaving the current group", context do
    %{first: first, second: second, group: group} = context
    added = "#{group}-added"

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "#{group}")
        (buffer-set-local! "#{second}" 'group "#{group}")
        (delete-other-windows!)
        (switch-to-buffer! "#{first}")
        (split-window! 'h 0.5)
        (other-window!)
        (switch-to-buffer! "#{second}")
        (set-frame-local! 'current-group "#{group}"))
      """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("A")
    type(added)
    KeyDispatch.handle_key("RET")

    assert Session.eval(~s{(buffer-groups "#{first}")}) ==
             {:ok, ~s{("#{group}" "#{added}")}}

    assert Session.eval(~s{(buffer-groups "#{second}")}) ==
             {:ok, ~s{("#{group}" "#{added}")}}

    assert Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{group}"}}
    assert Session.eval(~s{(equal? (group-layout "#{added}") (window-tree))}) == {:ok, "#t"}

    {:ok, _} = Session.eval(~s{(switch-to-group! "#{added}")})

    assert Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{added}"}}

    shown = Editor.list_windows() |> Enum.map(fn {_id, buffer} -> buffer end) |> Enum.sort()
    assert shown == Enum.sort([first, second])
  end

  test "killing one group preserves buffers shared with another group", context do
    %{first: first, second: second, group: group} = context
    other = "other-#{group}"

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "#{group}")
        (buffer-add-group! "#{first}" "#{other}")
        (buffer-set-local! "#{second}" 'group "#{group}")
        (group-kill! "#{group}"))
      """)

    assert Session.eval(~s{(buffer-exists? "#{first}")}) == {:ok, "#t"}
    assert Session.eval(~s{(buffer-groups "#{first}")}) == {:ok, ~s{("#{other}")}}
    assert Session.eval(~s{(buffer-exists? "#{second}")}) == {:ok, "#f"}
  end

  test "renaming a secondary group preserves the primary membership", context do
    %{first: first, group: group} = context
    renamed = "renamed-#{group}"

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{first}" 'group "primary-#{group}")
        (buffer-add-group! "#{first}" "#{group}")
        (group-rename! "#{group}" "#{renamed}"))
      """)

    assert Session.eval(~s{(buffer-groups "#{first}")}) ==
             {:ok, ~s{("primary-#{group}" "#{renamed}")}}
  end

  test "chat reset preserves additional group memberships", context do
    %{group: group} = context
    added = "#{group}-added"

    {:ok, _} =
      Session.eval("""
      (let ((chat (group-chat "#{group}")))
        (buffer-add-group! chat "#{added}")
        (switch-to-buffer! chat)
        (set-mode! "chat-mode")
        (run-command "chat-reset"))
      """)

    assert Session.eval(~s{(buffer-groups (group-chat "#{group}"))}) ==
             {:ok, ~s{("#{group}" "#{added}")}}

    assert Session.eval("(if (member 'groups chat-identity-locals) #t #f)") == {:ok, "#t"}
  end

  test "chat-new starts a second chat without replacing the first", context do
    %{group: group} = context
    first = "*chat:#{group}*"
    second = "*chat:#{group}:2*"

    {:ok, _} =
      Session.eval("""
      (begin
        (switch-to-buffer! (group-chat "#{group}"))
        (set-mode! "chat-mode")
        (buffer-append! "#{first}" "first conversation stays")
        (group-meta-set! "#{group}" "kept metadata")
        (group-noise-set! "#{group}" "loud")
        (run-command "chat-new"))
      """)

    assert Editor.current_buffer() == second
    assert Buffer.text(first) =~ "first conversation stays"
    refute Buffer.text(second) =~ "first conversation stays"
    assert Session.eval(~s{(buffer-group "#{second}")}) == {:ok, ~s{"#{group}"}}
    assert Session.eval(~s{(group-holder "#{group}")}) == {:ok, ~s{"#{first}"}}
    assert Session.eval(~s{(group-meta "#{group}")}) == {:ok, ~s{"kept metadata"}}
    assert Session.eval(~s{(group-noise "#{group}")}) == {:ok, ~s{"loud"}}
  end

  test "chat-reset clears only the current chat", context do
    %{group: group} = context
    first = "*chat:#{group}*"
    second = "*chat:#{group}:2*"

    {:ok, _} =
      Session.eval("""
      (begin
        (switch-to-buffer! (group-chat "#{group}"))
        (set-mode! "chat-mode")
        (buffer-append! "#{first}" "keep this conversation")
        (run-command "chat-new")
        (buffer-append! "#{second}" "reset only this conversation")
        (run-command "chat-reset"))
      """)

    assert Editor.current_buffer() == second
    assert Buffer.text(first) =~ "keep this conversation"
    refute Buffer.text(second) =~ "reset only this conversation"
    assert Buffer.text(second) =~ "companion · #{group}"
  end
end
