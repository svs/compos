defmodule Aimax.SwitchModalTest do
  @moduledoc """
  The merged switcher: ONE modal list buffer. Typing narrows (filter is
  the default act); C- chords act on rows — RET visits, C-k kills, C-SPC
  marks, C-t groups, C-g shows groups, ESC quits. The highlight previews
  into the window you came from, and dormant rows stay killable and
  visitable.

  C-x b opens the group-aware minibuffer prompt. The modal switcher remains
  available as M-x switch-to-buffer.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  @switch "*switch*"

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  # the client sends a space as "SPC" — the graphemes must too
  defp type(str),
    do: str |> String.graphemes() |> Enum.map(&if(&1 == " ", do: "SPC", else: &1)) |> press()

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp windows do
    {:ok, wins} = Session.eval("(window-list)")

    Regex.scan(~r/\((\d+) "([^"]+)"\)/, wins)
    |> Enum.map(fn [_, id, b] -> {String.to_integer(id), b} end)
  end

  defp home_shows(home), do: Enum.find_value(windows(), fn {id, b} -> if id == home, do: b end)

  # four buffers, the third one current, then the modal switcher
  defp open_switcher do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-ma*")
        (buffer-create "*zz-mb*")
        (buffer-create "*zz-md*")
        (buffer-create "*zz-mc*")
        (delete-other-windows!)
        (switch-to-buffer! "*zz-mc*")
        #t)})

    home = Enum.find_value(windows(), fn {id, b} -> if b == "*zz-mc*", do: id end)
    {:ok, _} = Session.eval(~s[(run-command "switch-to-buffer")])
    home
  end

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      for b <- ["*zz-ma*", "*zz-mb*", "*zz-mc*", "*zz-md*", @switch],
          do: Aimax.Core.kill_buffer(b)

      {:ok, _} =
        Session.eval(~s{(begin
          (for-each (lambda (b) (buffer-set-local! b 'group #f)) (buffer-list))
          (set-frame-local! 'current-group #f))})

      Editor.minibuffer_close()
      Editor.delete_other_windows()
    end)

    :ok
  end

  test "C-x b opens the modal switcher; the standing buffer is not an offer" do
    open_switcher()

    assert Editor.current_buffer() == @switch
    entries = eval!(~s{(map car (list-entries "#{@switch}"))})
    refute entries =~ "zz-mc", "the standing buffer is in the pool"
    assert entries =~ "zz-ma"
    assert entries =~ "zz-mb"
  end

  test "typing narrows, DEL widens, and the query never outlives the open" do
    open_switcher()

    type("zz-m")
    assert eval!(~s{(list-query "#{@switch}")}) == ~s{"zz-m"}
    entries = eval!(~s{(map car (list-entries "#{@switch}"))})
    assert entries =~ "zz-ma"
    refute entries =~ "*scratch*"

    type("a")
    entries = eval!(~s{(map car (list-entries "#{@switch}"))})
    assert entries =~ "zz-ma"
    refute entries =~ "zz-mb"

    press(["DEL"])
    assert eval!(~s{(list-query "#{@switch}")}) == ~s{"zz-m"}
    assert eval!(~s{(map car (list-entries "#{@switch}"))}) =~ "zz-mb"

    # a reopen drops the typed narrowing: the list opens wide
    press(["ESC"])
    open_switcher()
    assert eval!(~s{(list-query "#{@switch}")}) == ~s{""}
    press(["ESC"])
  end

  test "the narrowing is orderless over the marginalia" do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-ma*")
        (buffer-set-local! "*zz-ma*" 'mode-name "zz-textish")
        #t)})

    open_switcher()

    # one term matches the mode annotation, the other the name — any order
    type("zz-textish zz-ma")
    assert eval!(~s{(map car (list-entries "#{@switch}"))}) == ~s{("*zz-ma*")}

    press(List.duplicate("DEL", 16))
    type("ma zz-textish")
    assert eval!(~s{(map car (list-entries "#{@switch}"))}) == ~s{("*zz-ma*")}
    press(["ESC"])
  end

  test "file rows show the complete filename once, without repeating its path" do
    root = Path.join(System.tmp_dir!(), "switch-row-#{System.unique_integer([:positive])}")
    filename = "A complete and deliberately long filename for the switcher.txt"
    path = Path.join(root, filename)
    File.mkdir_p!(root)
    File.write!(path, "switch row\n")

    on_exit(fn ->
      Aimax.Core.kill_buffer(path)
      File.rm_rf!(root)
    end)

    {:ok, _} =
      Session.eval(~s{(begin
        (find-file "#{path}")
        (switch-to-buffer! "*zz-mc*")
        (switch-open! 'buffers)
        #t)})

    type("deliberately long")
    text = Buffer.text(@switch)

    assert text =~ filename
    assert length(String.split(text, filename)) == 2, "filename is repeated in the row"
    refute text =~ path
    assert text =~ "Fundamental"

    press(["ESC"])
  end

  test "moving the highlight previews into the home window; ESC puts it back" do
    home = open_switcher()

    type("zz-m")
    press(["C-n"])
    assert home_shows(home) =~ "zz-m", "preview did not land in the home window"

    press(["ESC"])
    assert home_shows(home) == "*zz-mc*", "ESC did not restore the home window"
    refute Enum.any?(windows(), fn {_, b} -> b == @switch end), "ESC left the popup open"
  end

  test "RET visits the selected row and closes the popup" do
    open_switcher()

    type("zz-ma")
    press(["RET"])

    assert Editor.current_buffer() == "*zz-ma*"
    refute Enum.any?(windows(), fn {_, b} -> b == @switch end), "RET left the popup open"
  end

  test "RET with no match founds a group named the narrowing" do
    name = "zz-found-#{System.unique_integer([:positive])}"
    open_switcher()

    # the founding makes the group's chat buffer; a rerun must not meet it
    on_exit(fn -> Aimax.Core.kill_buffer("*chat:#{name}*") end)

    type(name)
    press(["RET"])

    assert eval!("(group-names)") =~ name

    {:ok, _} =
      Session.eval(~s{(begin
        (for-each (lambda (b) (buffer-set-local! b 'group #f)) (buffer-list))
        (set-frame-local! 'current-group #f))})
  end

  test "C-k kills the row at point; marked rows die as a set" do
    open_switcher()

    type("zz-ma")
    press(["C-k"])
    refute eval!(~s{(buffer-known? "*zz-ma*")}) == "#t"
    assert Buffer.text("*messages*") =~ "killed 1 buffer"

    # C-a marks every shown row, C-k kills them as a set
    press(["DEL", "DEL", "DEL", "DEL", "DEL", "DEL"])
    type("zz-m")
    press(["C-a"])
    press(["C-k"])
    assert Buffer.text("*messages*") =~ "killed 2 buffers"
    refute eval!(~s{(buffer-known? "*zz-mb*")}) == "#t"
    refute eval!(~s{(buffer-known? "*zz-md*")}) == "#t"
  end

  test "C-t puts the marked buffers in a group" do
    open_switcher()

    type("zz-ma")
    press(["C-SPC"])
    press(["C-t"])
    assert Editor.snapshot().minibuffer, "C-t did not prompt for the group"
    type("zzg-set")
    press(["RET"])

    assert eval!(~s{(group-name (buffer-group "*zz-ma*"))}) == ~s{"zzg-set"}
    press(["ESC"])
  end

  test "C-g closes the modal — the quit key keeps its one meaning" do
    home = open_switcher()

    press(["C-g"])
    assert home_shows(home) == "*zz-mc*"
    refute Enum.any?(windows(), fn {_, b} -> b == @switch end), "C-g left the popup open"
  end

  test "the key bar rides the footer line, not the rows" do
    open_switcher()

    assert eval!(~s{(buffer-local "#{@switch}" 'footer-line)}) =~ "C-o groups"
    refute Buffer.text(@switch) =~ "RET switch"
    press(["ESC"])
  end

  test "C-o shows groups; RET switches the group and continues to its rows" do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-ma*")
        (buffer-set-local! "*zz-ma*" 'group "zzg-card")
        #t)})

    open_switcher()
    press(["C-o"])

    entries = eval!(~s{(map car (list-entries "#{@switch}"))})
    assert entries =~ "[zzg-card]", "the groups view has no card for the group"

    type("zzg-card")
    press(["RET"])

    # the group came up, and the second step is open: card first, rows after
    assert eval!("(group-name (frame-local 'current-group))") == ~s{"zzg-card"}
    assert Editor.current_buffer() == @switch
    assert eval!(~s{(buffer-local "#{@switch}" 'switch-view)}) == ~s{(locked "zzg-card")}
    assert eval!(~s{(map car (list-entries "#{@switch}"))}) =~ "zz-ma"

    # RET on the card (the default) keeps the group and closes
    press(["RET"])
    refute Enum.any?(windows(), fn {_, b} -> b == @switch end)
  end

  test "C-x G opens the groups view, and picking a group asks for a buffer in it" do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-ma*")
        (buffer-create "*zz-mb*")
        (buffer-set-local! "*zz-ma*" 'group "zzg-pick")
        (buffer-set-local! "*zz-mb*" 'group "zzg-pick")
        (delete-other-windows!)
        #t)})

    {:ok, _} = Session.eval(~s[(run-command "switch-groups")])
    assert Editor.current_buffer() == @switch
    assert eval!(~s{(buffer-local "#{@switch}" 'switch-view)}) == "groups"

    type("zzg-pick")
    press(["RET"])

    # the group came up, and the switcher reopened locked to its buffers
    assert eval!("(group-name (frame-local 'current-group))") == ~s{"zzg-pick"}
    assert Editor.current_buffer() == @switch
    entries = eval!(~s{(map car (list-entries "#{@switch}"))})
    assert entries =~ "zz-m"

    press(["ESC"])
  end

  test "a project-rooted group offers its files, and the card defaults to dired" do
    root = Path.join(System.tmp_dir!(), "switch-proj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: root)
    File.write!(Path.join(root, "notes.txt"), "hello\n")

    on_exit(fn ->
      Aimax.Core.kill_buffer(Path.join(root, "notes.txt"))
      Aimax.Core.kill_buffer(root)
      File.rm_rf!(root)

      # the remembered project must not outlive the test in the test home
      {:ok, _} =
        Session.eval(~s{(write-file! *projects-file*
          (string-append
            (string-join (remove (lambda (r) (equal? r "#{root}")) (known-projects)) "\n")
            "\n"))})
    end)

    # a remembered project shows in the groups view without any open buffer
    {:ok, _} = Session.eval(~s{(project-remember! "#{root}")})
    {:ok, _} = Session.eval(~s{(switch-open! 'groups)})
    assert eval!(~s{(map car (list-entries "#{@switch}"))}) =~ "[#{Path.basename(root)}]"
    press(["ESC"])

    {:ok, _} = Session.eval(~s{(switch-open! (list 'locked "#{root}"))})
    entries = eval!(~s{(map car (list-entries "#{@switch}"))})
    assert entries =~ "notes.txt"

    # the card leads as the default; RET on it opens dired at the root
    {:ok, _} = Session.eval(~s{(list-goto-first-entry "#{@switch}")})
    press(["RET"])
    assert Editor.current_buffer() == root

    # a file row visits the file, and the file joins the group
    {:ok, _} = Session.eval(~s{(switch-open! (list 'locked "#{root}"))})
    type("notes")
    press(["RET"])
    assert Editor.current_buffer() == Path.join(root, "notes.txt")
    assert eval!(~s{(group-name (buffer-group "#{root}/notes.txt"))}) == ~s{"#{root}"}
  end

  test "the chrome chord table serves the minibuffer prompt, not the modal buffer" do
    # which chord chrome claims is its own preference, so read the table
    claimed = eval!("(car (car *chrome-chord-commands*))") |> Jason.decode!()
    keys = claimed |> String.split(" ", trim: true) |> Enum.map_join(" ", &~s{"#{&1}"})

    # the command must open a prompt, not the modal *switch* buffer:
    # group-switch-buffer calls minibuffer-read-preview
    assert eval!(~s{(chrome--chord-command (list #{keys}))}) == ~s{"group-switch-buffer"}
  end
end
