defmodule Aimax.AnnotateTest do
  @moduledoc """
  One test: the click path from the browser.

  The annotation layer is Scheme and priv/tests/annotate-test.scm covers
  it — the overlays, the relocation, the list and its tabs, the verbs, the
  margin cards, the suggestion, the store.

  What stays is SchemeAPI.block_click/2, the Elixir entry a browser click
  arrives on. It looks a handler up in ETS and applies it; Scheme has no
  way in, which is what makes it the bridge.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  @buf "annotate-test.txt"
  @list "*annotations*"

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  # Session.eval returns the PRINTED value: strings keep their quotes,
  # numbers print bare. eval_s! unwraps one printed string.
  defp eval!(code) do
    {:ok, v} = Session.eval(code)
    v
  end

  defp eval_s!(code), do: eval!(code) |> String.trim("\"")

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    eval!("""
    (begin
      (buffer-create "#{@buf}")
      (switch-to-buffer! "#{@buf}")
      (buffer-insert! "#{@buf}" 0 "alpha beta\\ngamma delta\\nepsilon zeta\\n"))
    """)

    on_exit(fn ->
      for b <- [@list, @buf] do
        if Buffer.exists?(b), do: Aimax.Core.kill_buffer(b)
      end
    end)

    :ok
  end

  defp add(spec) do
    eval_s!(~s[(annotate! "#{@buf}" (quote #{spec}))])
  end

  defp llm_warning do
    add(~s[(source "llm" severity "warning" line 2 match "delta"
            title "Overstated claim" who "claude" when "now")])
  end

  defp reader_note do
    add(~s[(source "reader" severity "note" line 3 match "zeta"
            title "Keep, verbatim" who "Ada R." when "Wed")])
  end

  defp fix_ann do
    add(~s[(source "llm" severity "suggestion" line 1 match "beta"
            title "Rename" who "claude" when "now"
            fix-old "beta" fix-new "betta")])
  end

  test "a margin card click hands the focus back to the document" do
    id = reader_note()
    eval!(~s[(enable-minor-mode! "#{@buf}" "annotate-mode")])
    on_exit(fn -> if Buffer.exists?("*margin*"), do: Aimax.Core.kill_buffer("*margin*") end)

    # the margin refuses typing from its first frame, not only after restore
    assert eval!(~s[(buffer-read-only? "*margin*")]) == "#t"

    # the client focuses the clicked window before the handler runs —
    # reproduce that, then click the card
    eval!(~s[(unless (window-showing "*margin*")
               (display-buffer-other-window! "*margin*"))])
    eval!(~s[(select-window! (window-showing "*margin*"))])
    assert eval_s!(~s[(window-buffer (active-window))]) == "*margin*"

    Aimax.Core.SchemeAPI.block_click("*margin*", "ann:pick:#{id}")

    assert eventually(fn ->
             eval_s!(~s[(window-buffer (active-window))]) == @buf
           end)
  end


  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

end
