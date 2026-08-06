defmodule Aimax.WritingTest do
  @moduledoc "writing-mode: minor-mode infra, centered prose look, word count."

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
      fun.() -> :ok
      tries == 0 -> :timeout
      true ->
        Process.sleep(30)
        wait_until(fun, tries - 1)
    end
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    on_exit(fn -> Editor.minibuffer_close() end)
    :ok
  end

  test "M-x writing-mode enables the centered prose look" do
    buf = fresh_buffer("wr-mx-#{System.unique_integer([:positive])}", "one two three\n")

    press(["M-x"])
    type("writing-mode")
    press(["RET"])

    assert Buffer.get_local(buf, "minor-modes") == ["writing-mode"]
    assert Buffer.get_local(buf, "line-numbers") == "off"
    assert Buffer.get_local(buf, "window-class") == "writing"
    style = Buffer.get_local(buf, "style")
    assert style =~ "--default-family:Spectral, Georgia, serif;"
    assert style =~ "--writing-measure:62ch;"
    assert Buffer.get_local(buf, "modeline-info") =~ ~r/^3 words · 1 min$/
  end

  test "count-words counts whitespace-separated words" do
    buf = fresh_buffer("wr-cw-#{System.unique_integer([:positive])}", "a b  c\nd\n")
    assert eval!(~s{(count-words "#{buf}")}) == "4"
  end

  test "word count live-updates as you type" do
    buf = fresh_buffer("wr-live-#{System.unique_integer([:positive])}", "")
    eval!(~s{(run-command "writing-mode")})
    assert Buffer.get_local(buf, "modeline-info") == "0 words"

    type("hello brave new world")

    assert :ok =
             wait_until(fn ->
               Buffer.get_local(buf, "modeline-info") == "4 words · 1 min"
             end)
  end

  test "disabling restores the previous look (composes with org-mode)" do
    buf = fresh_buffer("wr-org-#{System.unique_integer([:positive])}.org", "* head\nbody\n")
    eval!(~s{(set-mode! "org-mode")})
    org_style = Buffer.get_local(buf, "style")
    assert org_style =~ "--default-size:14.5px;"

    eval!(~s{(run-command "writing-mode")})
    assert Buffer.get_local(buf, "style") =~ "--default-size:17px;"

    eval!(~s{(run-command "writing-mode")})
    assert Buffer.get_local(buf, "style") == org_style
    assert Buffer.get_local(buf, "minor-modes") == []
    refute Buffer.get_local(buf, "window-class")
    refute Buffer.get_local(buf, "modeline-info")
    refute Buffer.get_local(buf, "line-numbers")
    refute Buffer.get_local(buf, "writing-saved")
  end

  test "customizing the measure repaints live writing buffers" do
    buf = fresh_buffer("wr-cust-#{System.unique_integer([:positive])}", "words here\n")
    eval!(~s{(run-command "writing-mode")})
    assert Buffer.get_local(buf, "style") =~ "--writing-measure:62ch;"

    eval!(~s{(customize-set! 'writing-measure "44ch")})
    assert Buffer.get_local(buf, "style") =~ "--writing-measure:44ch;"

    eval!(~s{(customize-set! 'writing-measure "62ch")})
    eval!(~s{(run-command "writing-mode")})
  end

  test "restore-minor-modes! re-runs setup idempotently (reload path)" do
    buf = fresh_buffer("wr-restore-#{System.unique_integer([:positive])}", "some prose\n")
    eval!(~s{(run-command "writing-mode")})

    eval!(~s{(restore-minor-modes! "#{buf}")})

    hooks =
      eval!(~s{(length (filter (lambda (h) (equal? (car h) "#{buf}")) *writing-hooks*))})

    assert hooks == "1"
    assert Buffer.get_local(buf, "window-class") == "writing"
    assert Buffer.get_local(buf, "modeline-info") == "2 words · 1 min"
  end
end
