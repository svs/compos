defmodule Aimax.FullBrowserTest do
  @moduledoc "The interactive browser commands through the normal key path."

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    buf = eval!(~s{(full-browser "https://session.test/account")}) |> String.trim("\"")

    on_exit(fn ->
      Session.eval(~S{(begin
        (for-each (lambda (b)
                    (when (equal? (buffer-local b 'mode-name) "full-browser-mode")
                      (buffer-kill! b)))
                  (buffer-list))
        #t)})

      Editor.minibuffer_close()
      Editor.delete_other_windows()
    end)

    {:ok, buffer: buf}
  end

  test "reload through key dispatch replaces the iframe generation", %{buffer: buf} do
    before = Buffer.get_local(buf, "browser-generation")

    KeyDispatch.handle_key("r")

    assert Buffer.get_local(buf, "browser-generation") == before + 1
  end

  test "page mode cycles from raw to theme without replacing the live page", %{buffer: buf} do
    assert Buffer.get_local(buf, "browser-page-mode") == "raw-mode"

    KeyDispatch.handle_key("m")

    assert Editor.current_buffer() == buf
    assert Buffer.get_local(buf, "browser-page-mode") == "theme-mode"
    assert Buffer.get_local(buf, "modeline-info") == "theme-mode"
  end

  test "the address prompt navigates the current browser buffer", %{buffer: buf} do
    KeyDispatch.handle_key("g")
    assert Editor.render_state().minibuffer.prompt == "Web address: "

    Enum.each(String.graphemes("next.test/dashboard"), &KeyDispatch.handle_key/1)
    KeyDispatch.handle_key("RET")

    assert Editor.current_buffer() == buf
    assert Buffer.get_local(buf, "browser-url") == "https://next.test/dashboard"
    refute Buffer.get_local(buf, "header-line")
  end

  test "non-web schemes never reach the iframe" do
    assert {:error, error} = Session.eval(~s{(full-browser "javascript:alert(1)")})
    assert error =~ "only http and https"

    assert {:error, error} = Session.eval(~s{(full-browser "file:///tmp/private")})
    assert error =~ "only http and https"
  end
end
