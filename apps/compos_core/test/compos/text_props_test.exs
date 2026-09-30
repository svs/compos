defmodule Compos.TextPropsTest do
  @moduledoc """
  Text properties through the buffer and through Scheme: the Emacs API,
  the stickiness rules on insert, and positions that move with edits.
  """
  use ExUnit.Case

  alias Compos.Core.{Buffer, Session, TextProps}

  setup do
    name = "zz-props-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name, text: "hello brave new world\n")
    on_exit(fn -> Compos.Core.kill_buffer(name) end)
    {:ok, name: name}
  end

  test "put, get, and the change positions", %{name: b} do
    assert Buffer.get_text_property(b, 3, "face") == nil
    :ok = Buffer.put_text_property(b, 6, 11, "face", "bold")
    assert Buffer.get_text_property(b, 5, "face") == nil
    assert Buffer.get_text_property(b, 6, "face") == "bold"
    assert Buffer.get_text_property(b, 10, "face") == "bold"
    assert Buffer.get_text_property(b, 11, "face") == nil

    assert Buffer.next_single_property_change(b, 0, "face") == 6
    assert Buffer.next_single_property_change(b, 6, "face") == 11
    assert Buffer.next_single_property_change(b, 11, "face") == nil
    assert Buffer.next_single_property_change(b, 11, "face", 20) == 20
    assert Buffer.next_single_property_change(b, 0, "face", 4) == 4
    assert Buffer.previous_single_property_change(b, 20, "face") == 11
    assert Buffer.previous_single_property_change(b, 9, "face") == 6
    assert Buffer.previous_single_property_change(b, 3, "face") == nil

    assert Buffer.text_property_any(b, 0, 22, "face", "bold") == 6
    assert Buffer.text_property_any(b, 8, 22, "face", "bold") == 8
    assert Buffer.text_property_any(b, 0, 22, "face", "italic") == nil
    assert Buffer.text_property_any(b, 6, 22, "face", nil) == 11
    assert Buffer.text_property_any(b, 6, 11, "face", nil) == nil
    assert Buffer.text_properties_at(b, 7) == [{"face", "bold"}]
  end

  test "a write over a span splits it, and equal neighbours join", %{name: b} do
    :ok = Buffer.put_text_property(b, 0, 10, "face", "a")
    :ok = Buffer.put_text_property(b, 3, 5, "face", "b")
    assert Buffer.text_property_spans(b, "face") == [{0, 3, "a"}, {3, 5, "b"}, {5, 10, "a"}]

    :ok = Buffer.put_text_property(b, 3, 5, "face", "a")
    assert Buffer.text_property_spans(b, "face") == [{0, 10, "a"}]

    :ok = Buffer.remove_text_properties(b, 4, 6, ["face"])
    assert Buffer.text_property_spans(b, "face") == [{0, 4, "a"}, {6, 10, "a"}]

    :ok = Buffer.put_text_property(b, 0, 10, "face", nil)
    assert Buffer.text_property_spans(b, "face") == []
  end

  test "edits move a property with its text", %{name: b} do
    :ok = Buffer.put_text_property(b, 6, 11, "face", "bold")
    :ok = Buffer.insert_at(b, 0, "oh ")
    assert Buffer.text_property_spans(b, "face") == [{9, 14, "bold"}]
    :ok = Buffer.delete_range(b, 0, 3)
    assert Buffer.text_property_spans(b, "face") == [{6, 11, "bold"}]
    # a delete across the span keeps the part that stays
    :ok = Buffer.delete_range(b, 8, 5)
    assert Buffer.text_property_spans(b, "face") == [{6, 8, "bold"}]
  end

  test "a sticky property grows over text typed at its end, a nonsticky one does not", %{name: b} do
    :ok = Buffer.put_text_property(b, 6, 11, "face", "bold")
    :ok = Buffer.put_text_property(b, 6, 11, "zz-ns", true)
    TextProps.set_default_nonsticky("zz-ns", true)

    :ok = Buffer.insert_at(b, 11, "XY")
    assert Buffer.text_property_spans(b, "face") == [{6, 13, "bold"}]
    assert Buffer.text_property_spans(b, "zz-ns") == [{6, 11, true}]

    # inside the span: the sticky one grows, the nonsticky one splits
    :ok = Buffer.insert_at(b, 8, "Z")
    assert Buffer.text_property_spans(b, "face") == [{6, 14, "bold"}]
    assert Buffer.text_property_spans(b, "zz-ns") == [{6, 8, true}, {9, 12, true}]

    # at the start: no property is front-sticky
    :ok = Buffer.insert_at(b, 6, "Q")
    assert Buffer.text_property_spans(b, "face") == [{7, 15, "bold"}]
    assert Buffer.text_property_spans(b, "zz-ns") == [{7, 9, true}, {10, 13, true}]
  after
    TextProps.set_default_nonsticky("zz-ns", false)
  end

  test "the rear-nonsticky property of the character before the insert stops the growth", %{name: b} do
    :ok = Buffer.put_text_property(b, 0, 5, "face", "bold")
    :ok = Buffer.put_text_property(b, 0, 5, "rear-nonsticky", [{:sym, "face"}])
    :ok = Buffer.insert_at(b, 5, "!")
    assert Buffer.text_property_spans(b, "face") == [{0, 5, "bold"}]

    :ok = Buffer.put_text_property(b, 6, 11, "face", "dim")
    :ok = Buffer.insert_at(b, 11, "!")
    assert Buffer.text_property_spans(b, "face") == [{0, 5, "bold"}, {6, 12, "dim"}]
  end

  test "the Scheme primitives carry the Emacs names", %{name: b} do
    {:ok, printed} =
      Session.eval("""
      (begin
        (put-text-property! "#{b}" 6 11 'face 'bold)
        (list (get-text-property "#{b}" 7 'face)
              (get-text-property "#{b}" 2 'face)
              (next-single-property-change "#{b}" 0 'face)
              (next-single-property-change "#{b}" 6 'face)
              (next-single-property-change "#{b}" 11 'face)
              (next-single-property-change "#{b}" 11 'face 15)
              (previous-single-property-change "#{b}" 20 'face)
              (text-property-any "#{b}" 0 22 'face 'bold)
              (text-property-any "#{b}" 0 22 'face 'dim)
              (text-properties-at "#{b}" 8)
              (text-property-spans "#{b}" 'face)))
      """)

    assert printed == "(bold #f 6 11 #f 15 11 6 #f ((face bold)) ((6 11 bold)))"

    {:ok, printed} =
      Session.eval("""
      (begin
        (remove-text-properties! "#{b}" 0 22 '(face))
        (text-property-spans "#{b}" 'face))
      """)

    assert printed == "()"

    {:ok, printed} = Session.eval("(text-property-default-nonsticky)")
    assert printed =~ "fontified"
  end
end
