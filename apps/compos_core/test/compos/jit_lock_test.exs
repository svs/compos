defmodule Compos.JitLockTest do
  # the switch is global, so these tests do not run beside each other
  use ExUnit.Case, async: false
  alias Compos.Core.{Buffer, Display, Editor, JitLock, Session, TextProps}

  describe "marks" do
    test "gaps are the parts no mark covers" do
      assert JitLock.gaps(%{}, 0, 10) == [{0, 10}]
      marked = JitLock.mark(%{}, 0, 10, 1)
      assert JitLock.gaps(marked, 2, 8) == []
      two = %{} |> JitLock.mark(2, 4, 1) |> JitLock.mark(6, 8, 1)
      assert JitLock.gaps(two, 0, 10) == [{0, 2}, {4, 6}, {8, 10}]
    end

    test "a touch takes the mark off, and a forget takes every mark off" do
      marked = JitLock.mark(%{}, 0, 10, 1)
      assert JitLock.gaps(JitLock.touch(marked, 4, 6), 0, 10) == [{4, 6}]
      refute JitLock.marked?(JitLock.forget(marked))
    end

    test "a late request forgets its own text, or every mark of its version when it widened" do
      props = %{} |> JitLock.mark(0, 10, 3) |> JitLock.mark(10, 20, 3) |> JitLock.mark(20, 30, 4)
      assert JitLock.gaps(JitLock.forget_request(props, 3, 10), 0, 30) == [{10, 20}]
      assert JitLock.gaps(JitLock.forget_request(props, 3, 5), 0, 30) == [{0, 20}]
      assert JitLock.gaps(JitLock.forget_request(props, 9, 0), 0, 30) == []
    end

    test "fontified is not sticky, so typed text carries no mark" do
      assert JitLock.prop() in TextProps.default_nonsticky()
      props = JitLock.mark(%{}, 0, 10, 1)
      assert JitLock.gaps(TextProps.insert_gap(props, 10, 3), 0, 13) == [{10, 13}]
    end
  end

  describe "a buffer" do
    setup do
      name = "jit-lock-#{System.unique_integer([:positive])}"
      {:ok, _} = Compos.Core.create_buffer(name, text: "one\ntwo\nthree\nfour\n")

      {:ok, _} =
        Session.eval("""
        (begin
          (define *jit-test-calls* '())
          (define (jit-test-fn buf start end)
            (when (equal? buf "#{name}")
              (set! *jit-test-calls* (cons (list start end) *jit-test-calls*))))
          (jit-lock-register! 'jit-test-fn))
        """)

      on_exit(fn ->
        Session.eval("(jit-lock-unregister! 'jit-test-fn)")
        Compos.Core.kill_buffer(name)
      end)

      {:ok, name: name}
    end

    defp calls(want, tries \\ 100)
    defp calls(_want, 0), do: flunk("fontification-functions did not run")

    defp calls(want, tries) do
      {:ok, text} = Session.eval("(reverse *jit-test-calls*)")

      if text == want do
        text
      else
        Process.sleep(20)
        calls(want, tries - 1)
      end
    end

    test "each drawn range runs the hook once, and an edit runs only its line again",
         %{name: name} do
      v = Buffer.version(name)
      Buffer.request_jit(name, v, 0, 8)
      calls("((0 8))")

      # the same lines again, and a range that holds them: only the new part runs
      Buffer.request_jit(name, v, 0, 8)
      Buffer.request_jit(name, v, 0, 19)
      calls("((0 8) (8 19))")

      # an insert on line two ("two") takes back that line and no other
      Buffer.insert_at(name, 5, "X")
      Buffer.request_jit(name, Buffer.version(name), 0, 20)
      calls("((0 8) (8 19) (4 9))")
    end

    test "the mark is a text property that moves with the text", %{name: name} do
      v = Buffer.version(name)
      Buffer.request_jit(name, v, 8, 19)
      calls("((8 19))")
      assert Buffer.text_property_spans(name, "fontified") == [{8, 19, [v, 8]}]

      Buffer.insert_at(name, 0, "zero\n")
      assert Buffer.text_property_spans(name, "fontified") == [{13, 24, [v, 8]}]
      # typing at the end of the marked text leaves the new text unmarked
      Buffer.insert_at(name, 24, "five\n")
      assert Buffer.text_property_spans(name, "fontified") == [{13, 24, [v, 8]}]
    end

    test "a paint for an old version changes nothing and takes back only its own text",
         %{name: name} do
      v = Buffer.version(name)
      Buffer.request_jit(name, v, 0, 8)
      calls("((0 8))")
      Buffer.request_jit(name, v, 8, 19)
      calls("((0 8) (8 19))")

      # an edit lands before the second paint: the old positions name other bytes
      Buffer.insert_at(name, 0, "X")
      assert :stale == Buffer.set_overlays_range(name, "t", 8, 19, [{8, 13, "f"}], v)
      assert Buffer.overlays(name, "t") == []

      # the edit took back its own line, the late paint its range, and the
      # first range keeps its mark: the same draw asks for the two, not three
      Buffer.request_jit(name, Buffer.version(name), 0, 20)
      calls("((0 8) (8 19) (0 5) (9 20))")

      # a paint at the current version lands
      assert :ok ==
               Buffer.set_overlays_range(name, "t", 0, 5, [{0, 3, "f"}], Buffer.version(name))

      assert Buffer.overlays(name, "t") == [{0, 3, "f"}]
    end

    test "a refontify runs every drawn range again", %{name: name} do
      v = Buffer.version(name)
      Buffer.request_jit(name, v, 0, 8)
      calls("((0 8))")
      Buffer.jit_reset(name)
      Buffer.request_jit(name, Buffer.version(name), 0, 8)
      calls("((0 8) (0 8))")
    end
  end

  describe "a window" do
    setup do
      Editor.minibuffer_close()
      Editor.delete_other_windows()
      Editor.set_total_rows(20)
      name = "jit-window-#{System.unique_integer([:positive])}"
      Editor.set_window_buffer(name)
      # 400 KB: ten thousand lines of forty bytes
      Buffer.append(name, Enum.map_join(1..10_000, "\n", &String.pad_trailing("line #{&1}", 39)), source: :editor)
      Buffer.goto(name, 0)

      {:ok, _} =
        Session.eval("""
        (begin
          (define *jit-window-calls* '())
          (define (jit-window-fn buf start end)
            (when (equal? buf "#{name}")
              (set! *jit-window-calls* (cons (list start end) *jit-window-calls*))))
          (jit-lock-register! 'jit-window-fn))
        """)

      on_exit(fn ->
        Session.eval("(jit-lock-unregister! 'jit-window-fn)")
        Compos.Core.kill_buffer(name)
      end)

      {:ok, name: name}
    end

    defp drawn_bytes(tries \\ 100)
    defp drawn_bytes(0), do: flunk("fontification-functions did not run")

    defp drawn_bytes(tries) do
      {:ok, text} = Session.eval("(apply + (map (lambda (r) (- (cadr r) (car r))) *jit-window-calls*))")

      case Integer.parse(text) do
        {n, ""} when n > 0 -> n
        _ ->
          Process.sleep(20)
          drawn_bytes(tries - 1)
      end
    end

    test "a draw of a 400 KB buffer fontifies the drawn lines and no others", %{name: name} do
      leaf = Editor.render_state().tree
      assert leaf.buffer == name
      {drawn, _} = Display.window(leaf, nil)
      bytes = drawn_bytes()

      assert bytes <= length(drawn.lines) * 40 + 40
      assert bytes < 40_000
      assert Buffer.byte_size(name) > 390_000
    end
  end
end
