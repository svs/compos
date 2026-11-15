defmodule Compos.HomeSplitTest do
  # The contract of the home split: the home keeps the user's data, state
  # goes to the state folder, and what compos builds again to the cache.
  use ExUnit.Case, async: true

  alias Compos.Core.HomeSplit

  test "each entry of an old home goes to its kind, and data stays" do
    home = Path.join(System.tmp_dir!(), "zz-home-split-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)

    for dir <- ~w(buffers docs compos groups packages models grammars),
        do: File.mkdir_p!(Path.join(home, dir))

    for file <- ~w(desktop.etf events.db daemon.log init.scm custom.scm secrets.scm),
        do: File.write!(Path.join(home, file), "")

    moves = Map.new(HomeSplit.moves(home), fn {from, to} -> {Path.basename(from), Path.dirname(to)} end)
    state = Compos.Core.state_dir()

    assert moves["buffers"] == state
    assert moves["docs"] == state
    assert moves["desktop.etf"] == state
    assert moves["events.db"] == state
    assert moves["daemon.log"] == state
    assert moves["models"] == Compos.Core.cache_dir()
    assert moves["grammars"] == Compos.Core.machine_cache_dir()

    for data <- ~w(compos groups packages init.scm custom.scm secrets.scm),
        do: refute Map.has_key?(moves, data), "#{data} is the user's data and stays in the home"
  end

  test "boot gives the state folder its place apart from the home" do
    refute Path.expand(Compos.Core.state_dir()) == Path.expand(Compos.Core.home())
  end
end
