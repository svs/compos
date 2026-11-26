defmodule Compos.ManualTest do
  @moduledoc """
  The generated manual: docs/manual comes out of the editor's own
  registries (howto.scm). Every run renders it into a scratch directory,
  so a howto that cannot render fails here. `bin/docs` sets WRITE_MANUAL=1,
  and this test then writes the files into docs/manual.
  """

  use ExUnit.Case

  alias Compos.Core.Session

  # the apps the stock boot leaves out; the suite loads them (test_helper.exs)
  @opt_in ~w(title decide)

  @tag timeout: 300_000
  test "the manual renders from a stock boot" do
    dir =
      if System.get_env("WRITE_MANUAL") == "1" do
        Path.expand("../../../../docs/FURTHER READING/manual", __DIR__)
      else
        Path.join(System.tmp_dir!(), "compos-manual-#{System.unique_integer([:positive])}")
      end

    exclude = Enum.map_join(@opt_in, " ", &inspect/1)

    {:ok, _} = Session.eval(~s{(write-manual! #{inspect(dir)} (list #{exclude}))})

    howto = File.read!(Path.join(dir, "HOW-DO-I.md"))
    commands = File.read!(Path.join(dir, "COMMANDS.md"))

    assert howto =~ "How do I open a file?"
    refute howto =~ "{{"
    assert commands =~ "`how-do-i`"
    refute commands =~ "`doom"
    assert File.read!(Path.join(dir, "KEYS.md")) =~ "`kill-buffer`"

    unless System.get_env("WRITE_MANUAL") == "1", do: File.rm_rf!(dir)
  end
end
