defmodule Aimax.WritingTest do
  @moduledoc """
  One test, and one reason it cannot be Scheme.

  writing.scm is Scheme and priv/tests/writing-test.scm covers all of it —
  the look, the workspace, the selection keymap, the presets, the measure,
  the restore path and the word counter itself.

  What is left is the DELIVERY: typing updates the count through an
  on-change hook. That hook is a closure registered when write runs, and a
  closure only reaches shared state when its eval exits (Env's two-tier
  store). run-test is one eval per test, so no Scheme test can both
  register the hook and watch it fire. This one can, because ExUnit
  registers it in one eval and types in the next.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp fresh_buffer(name, text) do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    name
  end

  defp wait_until(fun, tries \\ 30) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        :timeout

      true ->
        Process.sleep(30)
        wait_until(fun, tries - 1)
    end
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])

    on_exit(fn ->
      Editor.minibuffer_close()

      {:ok, _} =
        Session.eval("""
        (for-each
          (lambda (b)
            (when (minor-mode-on? b "writing-mode")
              (disable-minor-mode! b "writing-mode")))
          (buffer-list))
        """)

      Aimax.Core.list_buffers()
      |> Enum.filter(
        &(String.starts_with?(&1, "*writing:") or String.starts_with?(&1, "*scratch:") or
            String.starts_with?(&1, "*chat:"))
      )
      |> Enum.each(&Aimax.Core.kill_buffer/1)
    end)

    :ok
  end

  test "word count live-updates as you type" do
    buf = fresh_buffer("wr-live-#{System.unique_integer([:positive])}", "")
    eval!(~s{(run-command "write")})
    assert Buffer.get_local(buf, "modeline-info") == "0 words"

    type("hello brave new world")

    assert :ok =
             wait_until(fn ->
               Buffer.get_local(buf, "modeline-info") == "4 words · 1 min"
             end)
  end



end
