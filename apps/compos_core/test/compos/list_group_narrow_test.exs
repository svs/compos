defmodule Compos.ListGroupNarrowTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}
  defp eval!(code), do: elem(Session.eval(code), 1)
  defp keys(specs), do: Enum.each(specs, &KeyDispatch.handle_key/1)

  for mode <- ["ibuffer-mode", "chat-list-mode"] do
    @mode mode
    test "#{mode} narrows a group, preserves text filtering, and widens" do
      Editor.minibuffer_close()
      Compos.TestHelpers.one_window!()
      Editor.set_window_buffer("*scratch*")

      for name <- ["zz-scope-a", "zz-scope-b", "zz-scope-c"] do
        Compos.Core.create_buffer(name, text: "")
        Buffer.set_local(name, "mode-name", "chat-mode")
      end

      eval!("""
      (define *zz-scope-opts* (list-mode-opts "#{@mode}"))
      (define-list-mode! "#{@mode}"
        (ibuffer-plist-put
          (ibuffer-plist-put *zz-scope-opts* 'stamp #f)
          'rows (lambda (buf)
            (append (ibuffer-section buf "First" "first" '("zz-scope-a" "zz-scope-b") "faint")
                    (ibuffer-section buf "Second" "second" '("zz-scope-c") "faint")))))
      (list-mode-show! "#{@mode}")
      (define *zz-scope-view* (current-buffer))
      (list-goto-index! *zz-scope-view* 1)
      """)

      on_exit(fn ->
        Editor.minibuffer_close()
        eval!("(define-list-mode! \"#{@mode}\" *zz-scope-opts*)")
        Editor.set_window_buffer("*scratch*")

        for name <- ["zz-scope-a", "zz-scope-b", "zz-scope-c", "*ibuffer*", "*chat-list*"],
            do: Compos.Core.kill_buffer(name)
      end)

      keys(["C-x", "n", "n"])

      assert eval!("(filter string? (list-entries *zz-scope-view*))") ==
               ~s{("zz-scope-a" "zz-scope-b")}

      eval!("(list-refresh! *zz-scope-view*)")

      assert eval!("(filter string? (list-entries *zz-scope-view*))") ==
               ~s{("zz-scope-a" "zz-scope-b")}

      eval!("(list-set-query! *zz-scope-view* \"zz-scope-\")")
      keys(["C-x", "n", "w"])
      assert eval!("(list-query *zz-scope-view*)") == ~s{"zz-scope-"}

      assert eval!("(filter string? (list-entries *zz-scope-view*))") ==
               ~s{("zz-scope-a" "zz-scope-b" "zz-scope-c")}

      # A folded group still narrows by its heading and unfolds in that scope.
      eval!("""
      (list-set-query! *zz-scope-view* "")
      (ibuffer-toggle-fold! "first" *zz-scope-view*)
      (list-goto-index! *zz-scope-view* 0)
      """)

      keys(["C-x", "n", "n"])
      assert eval!("(length (list-entries *zz-scope-view*))") == "1"
      eval!("(ibuffer-toggle-fold! \"first\" *zz-scope-view*)")

      assert eval!("(filter string? (list-entries *zz-scope-view*))") ==
               ~s{("zz-scope-a" "zz-scope-b")}

      keys(["C-x", "n", "w"])
      assert eval!("(length (filter string? (list-entries *zz-scope-view*)))") == "3"
    end
  end
end
