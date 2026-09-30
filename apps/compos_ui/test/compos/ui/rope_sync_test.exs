defmodule Compos.Ui.RopeSyncTest do
  @moduledoc """
  The text sync for the browser's rope. The client gets the whole text
  once, then one change per version, point, and the last input sequence
  number the daemon ran. Only a window with predict-mode on gets it.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  alias Compos.Core.{Buffer, Editor, Session}
  alias Compos.Ui.RopeSync

  describe "delta/2" do
    test "the change between two texts is one replacement" do
      assert RopeSync.delta("abc", "abXc") == {2, 0, "X"}
      assert RopeSync.delta("abc", "ac") == {1, 1, ""}
      assert RopeSync.delta("abc", "abc") == {3, 0, ""}
      assert RopeSync.delta("", "hi") == {0, 0, "hi"}
      assert RopeSync.delta("one\ntwo", "one\nTWO") == {4, 3, "TWO"}
    end

    test "both ends stop on a char boundary" do
      # é is C3 A9 and è is C3 A8: the bytes share a lead byte
      assert RopeSync.delta("é", "è") == {0, 2, "è"}
      assert RopeSync.delta("aé", "aè") == {1, 2, "è"}
      # ü is C3 BC and ö is C3 B6: a shared tail byte never splits a char
      assert RopeSync.delta("xüy", "xöy") == {1, 2, "ö"}
      {at, del, ins} = RopeSync.delta("日本", "日木")
      assert String.valid?(ins)
      assert {at, del} == {3, 3}
    end

    test "applying the delta to the old text gives the new text" do
      pairs = [
        {"hello world", "hello brave world"},
        {"línea uno\nlínea dos", "línea uno\nlínea tres"},
        {"aaaa", "aa"},
        {"🙂🙂", "🙂🙃🙂"}
      ]

      for {old, new} <- pairs do
        {at, del, ins} = RopeSync.delta(old, new)
        rebuilt = binary_part(old, 0, at) <> ins <> binary_part(old, at + del, byte_size(old) - at - del)
        assert rebuilt == new
      end
    end
  end

  describe "the rope event" do
    setup do
      Editor.minibuffer_close()
      Editor.set_total_rows(40)
      Editor.delete_other_windows()
      {:ok, conn: build_conn()}
    end

    defp buffer!(text, predict?) do
      name = "rope-sync-#{System.unique_integer([:positive])}"
      Editor.set_window_buffer(name)
      :ok = Buffer.append(name, text, source: :editor)
      Buffer.goto(name, byte_size(text))

      if predict?,
        do: {:ok, _} = Session.eval(~s|(enable-minor-mode! "#{name}" "predict-mode")|)

      name
    end

    defp hook(view, event, params), do: view |> element("#editor") |> render_hook(event, params)

    test "a predict-mode window gets the text, then one change per input", %{conn: conn} do
      buf = buffer!("ab", true)
      {:ok, view, _} = live(conn, "/")
      assert_push_event(view, "rope", %{text: "ab", pt: 2, ack: 0})

      hook(view, "intent", %{"type" => "insertText", "from" => 2, "to" => 2, "text" => "c", "seq" => 1})
      assert Buffer.text(buf) == "abc"
      assert_push_event(view, "rope", %{at: 2, del: 0, ins: "c", pt: 3, ack: 1})

      hook(view, "key", %{"k" => "DEL", "seq" => 2})
      assert Buffer.text(buf) == "ab"
      assert_push_event(view, "rope", %{at: 2, del: 1, ins: "", pt: 2, ack: 2})
    end

    test "an input that changes no text still acks its sequence number", %{conn: conn} do
      buf = buffer!("ab", true)
      {:ok, view, _} = live(conn, "/")
      assert_push_event(view, "rope", %{text: "ab"})

      hook(view, "key", %{"k" => "C-a", "seq" => 7})
      assert Buffer.point(buf) == 0
      assert_push_event(view, "rope", %{pt: 0, ack: 7} = payload)
      refute Map.has_key?(payload, :at)
      refute Map.has_key?(payload, :text)
    end

    test "a window without predict-mode gets no rope event", %{conn: conn} do
      _buf = buffer!("ab", false)
      {:ok, view, _} = live(conn, "/")
      hook(view, "intent", %{"type" => "insertText", "from" => 2, "to" => 2, "text" => "c", "seq" => 1})
      refute_push_event(view, "rope", %{})
    end
  end
end
