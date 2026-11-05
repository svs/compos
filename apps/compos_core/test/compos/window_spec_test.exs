defmodule Compos.WindowSpecTest do
  @moduledoc "Every tree shape an older desktop file holds reads to the same spec."

  use ExUnit.Case, async: true

  alias Compos.Core.WindowSpec

  @plain %{type: :leaf, buffer: "b", top: 3, manual: false, ctop: 0, id: nil}

  test "each positional leaf reads by position, with defaults for what it lacks" do
    assert WindowSpec.read({:leaf, "b"}) == %{@plain | top: 0}
    assert WindowSpec.read({:leaf, "b", 3}) == @plain
    assert WindowSpec.read({:leaf, "b", 3, 9}) == @plain
    assert WindowSpec.read({:leaf, "b", 3, 9, true, nil}) == %{@plain | manual: true}
    # a saved offset is itself the pin
    assert WindowSpec.read({:leaf, "b", 3, 9, false, 40, []}) == %{@plain | manual: true, ctop: 40}
    assert WindowSpec.read({:leaf, "b", 3, 9, false, 0, [], :r, :o}) == @plain
    assert WindowSpec.read({:leaf, "b", 3, 9, false, 0, [], nil, nil, 7}) == %{@plain | id: 7}
  end

  test "splits read with their ratio, and a spec reads to itself" do
    spec = %{type: :split, dir: :v, ratio: 0.5, children: [@plain, %{@plain | id: 7}]}

    assert WindowSpec.read({:split, :v, {:leaf, "b", 3}, {:leaf, "b", 3, 0, false, 0, [], nil, nil, 7}}) ==
             spec

    assert WindowSpec.read(spec) == spec
    assert WindowSpec.buffers(spec) == ["b", "b"]
  end
end
