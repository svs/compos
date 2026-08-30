defmodule Compos.FileViewTest do
  use ExUnit.Case

  alias Compos.Core.{Buffer, KeyDispatch, Session}

  @json "zz-file-view-command.json"

  setup do
    on_exit(fn -> Compos.Core.kill_buffer(@json) end)
    :ok
  end

  test "the focused Scheme file-view tests pass" do
    for name <- [
          "json-mode-formats-compact-json-without-changing-json-literals",
          "json-mode-leaves-invalid-json-unchanged",
          "browser-file-mode-draws-common-images-with-the-browser-viewer",
          "file-view-modes-and-commands-are-discoverable-with-declared-effects"
        ] do
      assert eval!("(begin (load-tests!) (run-test '#{name}))") == "()", name
    end
  end

  test "the JSON format command works through key dispatch" do
    compact = inspect(~s({"a":[1,2]}))
    replacement = inspect(~s({"b":false}))

    eval!("""
    (begin
      (test-buffer! "#{@json}" #{compact})
      (switch-to-buffer! "#{@json}")
      (set-mode! "json-mode")
      (buffer-replace-range! "#{@json}" 0 (buffer-size "#{@json}") #{replacement})
      (local-set-key* "#{@json}" "<f9> j" "json-pretty-print-buffer")
      #t)
    """)

    assert :ok = KeyDispatch.handle_key("<f9>")
    assert :ok = KeyDispatch.handle_key("j")

    assert Buffer.text(@json) == "{\n  \"b\": false\n}\n"
  end

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end
end
