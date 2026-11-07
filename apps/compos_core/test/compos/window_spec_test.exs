defmodule Compos.WindowSpecTest do
  @moduledoc "Every window shape an older desktop file holds reads to the same spec."

  use ExUnit.Case, async: true

  alias Compos.Core.WindowSpec

  @plain %{type: :leaf, buffer: "b", top: 3, manual: false, ctop: 0, id: nil, share: 1, dock: false}

  test "each positional leaf reads by position, with defaults for what it lacks" do
    assert WindowSpec.read({:leaf, "b"}) == %{@plain | top: 0}
    assert WindowSpec.read({:leaf, "b", 3}) == @plain
    assert WindowSpec.read({:leaf, "b", 3, 9}) == @plain
    assert WindowSpec.read({:leaf, "b", 3, 9, true, nil}) == %{@plain | manual: true}
    # a saved offset is itself the pin
    pinned = %{@plain | manual: true, ctop: 40}
    assert WindowSpec.read({:leaf, "b", 3, 9, false, 40, []}) == pinned
    assert WindowSpec.read({:leaf, "b", 3, 9, false, 0, [], :r, :o}) == @plain
    assert WindowSpec.read({:leaf, "b", 3, 9, false, 0, [], nil, nil, 7}) == %{@plain | id: 7}
  end

  test "an older split tree reads as a row of its leaves, and a spec reads to itself" do
    spec = %{type: :row, children: [@plain, %{@plain | id: 7}]}

    old = {:split, :v, {:leaf, "b", 3}, {:leaf, "b", 3, 0, false, 0, [], nil, nil, 7}}
    assert WindowSpec.read(old) == spec
    assert WindowSpec.read(%{type: :split, dir: :h, ratio: 0.3, children: [@plain, %{@plain | id: 7}]}) == spec

    assert WindowSpec.read(spec) == spec
    assert WindowSpec.buffers(spec) == ["b", "b"]
  end
end
