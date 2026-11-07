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
    pinned = %{@plain | manual: true, ctop: 40}
    assert WindowSpec.read({:leaf, "b", 3, 9, false, 40, []}) == pinned
    assert WindowSpec.read({:leaf, "b", 3, 9, false, 0, [], :r, :o}) == @plain
    assert WindowSpec.read({:leaf, "b", 3, 9, false, 0, [], nil, nil, 7}) == %{@plain | id: 7}
  end

  test "splits read with their ratio, and a spec reads to itself" do
    spec = %{type: :split, dir: :v, ratio: 0.5, children: [@plain, %{@plain | id: 7}]}

    old = {:split, :v, {:leaf, "b", 3}, {:leaf, "b", 3, 0, false, 0, [], nil, nil, 7}}
    assert WindowSpec.read(old) == spec

    assert WindowSpec.read(spec) == spec
    assert WindowSpec.buffers(spec) == ["b", "b"]
  end
  test "a row saved by the flat-row editor reads as splits that keep each share" do
    leaf = fn b, share -> %{type: :leaf, buffer: b, top: 3, id: nil, share: share, dock: false} end
    plain = fn b -> %{@plain | buffer: b} end

    row = %{
      type: :row,
      children: [
        leaf.("a", 0.5),
        leaf.("b", 0.25),
        leaf.("c", 0.25),
        %{leaf.("prompt", 0.4) | dock: true}
      ]
    }

    assert WindowSpec.read(row) == %{
             type: :split,
             dir: :h,
             ratio: 0.5,
             children: [
               plain.("a"),
               %{type: :split, dir: :h, ratio: 0.5, children: [plain.("b"), plain.("c")]}
             ]
           }

    assert WindowSpec.read(%{type: :row, children: [leaf.("a", 1)]}) == plain.("a")
  end
end
