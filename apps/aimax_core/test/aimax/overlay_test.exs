defmodule Aimax.OverlayTest do
  use ExUnit.Case

  alias Aimax.Core
  alias Aimax.Core.Buffer

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp new_buf(text) do
    name = uniq("ov")
    {:ok, ^name} = Core.create_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    name
  end

  test "set/clear per tag, flat read, generation bumps" do
    b = new_buf("hello world")
    assert Buffer.overlays(b) == []
    g0 = Buffer.overlay_gen(b)

    :ok = Buffer.set_overlays(b, "org", [{0, 5, "org-level-1"}])
    :ok = Buffer.set_overlays(b, "spell", [{6, 11, "warn"}])
    assert Enum.sort(Buffer.overlays(b)) == [{0, 5, "org-level-1"}, {6, 11, "warn"}]
    assert Buffer.overlay_gen(b) == g0 + 2

    # replace-per-tag semantics
    :ok = Buffer.set_overlays(b, "org", [{1, 2, "x"}])
    assert {1, 2, "x"} in Buffer.overlays(b)
    refute {0, 5, "org-level-1"} in Buffer.overlays(b)

    :ok = Buffer.clear_overlays(b, "spell")
    assert Buffer.overlays(b) == [{1, 2, "x"}]

    :ok = Buffer.clear_overlays(b)
    assert Buffer.overlays(b) == []
  end

  test "overlays shift on insert and delete like the mark" do
    b = new_buf("abcdef")
    :ok = Buffer.set_overlays(b, "t", [{2, 4, "f"}])

    # insert before: whole range shifts
    :ok = Buffer.insert_at(b, 0, "xx")
    assert Buffer.overlays(b) == [{4, 6, "f"}]

    # insert inside: end extends
    :ok = Buffer.insert_at(b, 5, "y")
    assert Buffer.overlays(b) == [{4, 7, "f"}]

    # delete after: untouched
    :ok = Buffer.delete_range(b, 7, 1)
    assert Buffer.overlays(b) == [{4, 7, "f"}]

    # delete spanning the whole range: overlay dropped
    :ok = Buffer.delete_range(b, 3, 5)
    assert Buffer.overlays(b) == []
  end

  test "hidden ranges adjust the same way" do
    b = new_buf("one\ntwo\nthree\n")
    :ok = Buffer.set_hidden(b, [{4, 8}])
    :ok = Buffer.insert_at(b, 0, "!!")
    assert Buffer.hidden(b) == [{6, 10}]

    :ok = Buffer.delete_range(b, 0, 2)
    assert Buffer.hidden(b) == [{4, 8}]
  end

  test "text inserted exactly at a range end stays outside it" do
    b = new_buf("head\nbody\n")
    :ok = Buffer.set_hidden(b, [{5, 10}])
    :ok = Buffer.set_overlays(b, "t", [{5, 10, "f"}])

    # append at the end boundary: a closed fold must not swallow it
    :ok = Buffer.insert_at(b, 10, "reply\n")
    assert Buffer.hidden(b) == [{5, 10}]
    assert Buffer.overlays(b) == [{5, 10, "f"}]

    # insert at the start boundary: the range shifts, the text stays outside
    :ok = Buffer.insert_at(b, 5, "x")
    assert Buffer.hidden(b) == [{6, 11}]
    assert Buffer.overlays(b) == [{6, 11, "f"}]
  end

  test "scheme primitives round-trip" do
    b = new_buf("hello world")

    {:ok, printed} =
      Aimax.Core.Session.eval("""
      (begin
        (overlay-set! "#{b}" 'org (list (list 0 5 'org-todo) (list 6 11 "org-done")))
        (buffer-overlays "#{b}"))
      """)

    assert printed == ~s{((0 5 "org-todo") (6 11 "org-done"))}

    {:ok, hidden} =
      Aimax.Core.Session.eval("""
      (begin
        (buffer-set-hidden! "#{b}" (list (list 5 11)))
        (buffer-hidden "#{b}"))
      """)

    assert hidden == "((5 11))"

    {:ok, _} = Aimax.Core.Session.eval(~s{(overlay-clear! "#{b}" 'all)})
    assert Buffer.overlays(b) == []
  end

  # Undo used to swap a whole rope snapshot in, leaving every range stale for
  # the mode to heal. It now applies the change the document worked out, and
  # the same adjustment every other edit uses moves the ranges with the text.
  test "undo adjusts ranges like any other change" do
    b = new_buf("abc")
    :ok = Buffer.set_overlays(b, "t", [{0, 3, "f"}])
    :ok = Buffer.insert_at(b, 0, "Z")
    assert Buffer.overlays(b) == [{1, 4, "f"}]
    :ok = Buffer.undo(b)
    assert Buffer.text(b) == "abc"
    assert Buffer.overlays(b) == [{0, 3, "f"}]
  end
end
