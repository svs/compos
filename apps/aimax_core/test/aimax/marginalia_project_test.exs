defmodule Aimax.MarginaliaProjectTest do
  @moduledoc """
  One test, and it is red.

  The annotator registry, the column padding, the prompt hints and the
  project lookups are Scheme and live in priv/tests/marginalia-test.scm.

  This one narrows the MODAL switcher, which types through
  switch-self-insert — it reads the key that ran it. It fails here today
  and in every baseline, so it is kept as the record rather than ported.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer("mp-#{System.unique_integer([:positive])}")
    on_exit(fn -> Editor.minibuffer_close() end)
    :ok
  end

  describe "marginalia" do
    # One annotator serves the prompt and the switcher: the modal list
    # narrows by the same marginalia text the prompt matches.
    test "the switcher narrows by the annotation the marginalia supplies" do
      on_exit(fn ->
        for b <- ["*mp-ga*", "*mp-gb*", "*switch*"], do: Aimax.Core.kill_buffer(b)
      end)

      {:ok, _} =
        Session.eval(~s{(begin
          (buffer-create "*mp-ga*")
          (buffer-create "*mp-gb*")
          (buffer-set-local! "*mp-ga*" 'group "work/dishwasher")
          (run-command "ibuffer"))})

      assert Aimax.Core.Buffer.text("*switch*") =~ "*mp-gb*"

      # the group is nowhere in the name: it is what the annotator says
      type("dishwasher")
      text = Aimax.Core.Buffer.text("*switch*")
      assert text =~ "*mp-ga*"
      refute text =~ "*mp-gb*"
      assert text =~ "/dishwasher"
      assert {:ok, ~s{"*mp-ga*"}} = Session.eval(~s{(car (list-current "*switch*"))})
      press(["ESC"])
    end


  end

end
