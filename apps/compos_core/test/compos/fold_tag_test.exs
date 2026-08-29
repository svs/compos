defmodule Compos.FoldTagTest do
  @moduledoc """
  Tagged folds, and the two payload fields the code browser needs.

  A buffer has several fold owners — org headlines, agent tool output, diff
  hunks, code bodies. Before tags, whichever owner wrote last erased the
  rest. Each owner now replaces only its own tag, and the display hides the
  union.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, Session}

  defp new_buf(text) do
    name = "fold-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    name
  end

  # the union as the renderer sees it, straight off the snapshot
  defp snapshot_hidden(buf), do: Buffer.render_snapshot(buf).hidden

  # "one\ntwo\nthree\nfour\nfive\n"
  #  0..3 4..7 8...13 14..18 19..23
  defp fixture, do: "one\ntwo\nthree\nfour\nfive\n"

  test "two owners fold one buffer without erasing each other" do
    b = new_buf(fixture())

    :ok = Buffer.set_hidden(b, "org", [{3, 7}])
    :ok = Buffer.set_hidden(b, "agent", [{13, 18}])

    assert Buffer.hidden(b, "org") == [{3, 7}]
    assert Buffer.hidden(b, "agent") == [{13, 18}]
    assert snapshot_hidden(b) == [{3, 7}, {13, 18}]

    # clearing one leaves the other exactly where it was
    :ok = Buffer.clear_hidden(b, "org")
    assert Buffer.hidden(b, "org") == []
    assert Buffer.hidden(b, "agent") == [{13, 18}]
    assert snapshot_hidden(b) == [{13, 18}]

    :ok = Buffer.clear_hidden(b)
    assert snapshot_hidden(b) == []
  end

  test "an owner replaces only its own ranges" do
    b = new_buf(fixture())

    :ok = Buffer.set_hidden(b, "org", [{3, 7}])
    :ok = Buffer.set_hidden(b, "agent", [{13, 18}])
    :ok = Buffer.set_hidden(b, "org", [{7, 13}])

    assert snapshot_hidden(b) == [{7, 13}, {13, 18}]
  end

  test "the untagged setter is one owner among the rest" do
    b = new_buf(fixture())

    :ok = Buffer.set_hidden(b, [{3, 7}])
    :ok = Buffer.set_hidden(b, "agent", [{13, 18}])

    assert Buffer.hidden(b, "default") == [{3, 7}]
    assert Buffer.hidden(b) == [{3, 7}, {13, 18}]
  end

  test "an edit adjusts every tag's ranges" do
    b = new_buf(fixture())

    :ok = Buffer.set_hidden(b, "org", [{3, 7}])
    :ok = Buffer.set_hidden(b, "agent", [{13, 18}])

    :ok = Buffer.insert_at(b, 0, "!!", source: :editor)
    assert Buffer.hidden(b, "org") == [{5, 9}]
    assert Buffer.hidden(b, "agent") == [{15, 20}]

    # a delete that swallows one range drops it and keeps the other
    :ok = Buffer.delete_range(b, 5, 4, source: :editor)
    assert Buffer.hidden(b, "org") == []
    assert Buffer.hidden(b, "agent") == [{11, 16}]
  end

  test "line motion skips a fold from any tag" do
    b = new_buf(fixture())
    :ok = Buffer.goto(b, 0)
    :ok = Buffer.set_hidden(b, "agent", [{3, 13}])

    # next-line from line 1 lands past the hidden body, on "four"
    assert Buffer.next_line(b) == 14
  end

  # --- the Scheme surface ----------------------------------------------------

  test "fold-set!, fold-get and fold-clear! carry the tag" do
    b = new_buf(fixture())

    {:ok, printed} =
      Session.eval("""
      (begin
        (fold-set! "#{b}" 'org (list (list 3 7)))
        (fold-set! "#{b}" 'agent (list (list 13 18)))
        (list (fold-get "#{b}" 'org) (fold-get "#{b}" 'agent) (fold-get "#{b}")))
      """)

    assert printed == "(((3 7)) ((13 18)) ((3 7) (13 18)))"

    {:ok, printed} =
      Session.eval("""
      (begin (fold-clear! "#{b}" 'org) (list (fold-get "#{b}" 'org) (fold-get "#{b}")))
      """)

    assert printed == "(() ((13 18)))"

    {:ok, "()"} = Session.eval(~s[(begin (fold-clear! "#{b}" 'all) (fold-get "#{b}"))])
  end

  test "fold-toggle! adds and removes one range" do
    b = new_buf(fixture())

    {:ok, printed} =
      Session.eval("""
      (begin
        (fold-toggle! "#{b}" 'diff (list 3 7))
        (fold-toggle! "#{b}" 'diff (list 13 18))
        (fold-get "#{b}" 'diff))
      """)

    assert printed == "((3 7) (13 18))"

    {:ok, printed} =
      Session.eval("""
      (begin (fold-toggle! "#{b}" 'diff (list 3 7)) (fold-get "#{b}" 'diff))
      """)

    assert printed == "((13 18))"
  end

  # --- restore ---------------------------------------------------------------

  test "an org buffer's folds come back when the mode setup runs again" do
    name = "restore-#{System.unique_integer([:positive])}.org"
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, "* a\nbody\n** child\ncbody\n* b\ntail\n", source: :editor)

    {:ok, _} = Session.eval(~s{(set-mode! "org-mode")})
    :ok = Buffer.goto(name, 0)
    {:ok, _} = Session.eval(~s{(run-command "org-cycle")})
    assert Buffer.hidden(name) == [{3, 23}]

    # a daemon restart loses the ranges and keeps the locals. Restore re-runs
    # the setup fn, which must re-derive the ranges with no edit in between.
    :ok = Buffer.clear_hidden(name)
    assert Buffer.hidden(name) == []
    assert Buffer.get_local(name, "org-folds") == [0]

    {:ok, _} = Session.eval(~s{(set-mode! "org-mode")})
    assert Buffer.hidden(name) == [{3, 23}]
  end

  # --- the leaf payload ------------------------------------------------------

  test "a leaf carries the buffer's path and read-only flag" do
    path = Path.join(System.tmp_dir!(), "compos-leaf-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "hello\n")
    on_exit(fn -> File.rm_rf!(path) end)

    Editor.minibuffer_close()
    Editor.delete_other_windows()
    {:ok, buf} = Compos.Core.open_file(path)
    Editor.set_window_buffer(buf)

    leaf = active_leaf()
    assert leaf.buffer == buf
    assert leaf.path == path
    assert leaf.read_only == false

    {:ok, _} = Session.eval(~s[(buffer-set-read-only! "#{buf}" #t)])
    assert active_leaf().read_only == true
  end

  test "a buffer with no file has no path" do
    b = new_buf("scratch\n")
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(b)

    leaf = active_leaf()
    assert leaf.buffer == b
    assert leaf.path == nil
  end

  defp active_leaf do
    payload = Editor.render_state()
    find_leaf(payload.tree, payload.active)
  end

  defp find_leaf(%{type: :leaf, id: id} = leaf, id), do: leaf
  defp find_leaf(%{type: :leaf}, _id), do: nil

  defp find_leaf(%{type: :split, children: children}, id),
    do: Enum.find_value(children, &find_leaf(&1, id))
end
