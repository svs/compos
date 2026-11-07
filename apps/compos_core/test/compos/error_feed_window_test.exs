defmodule Compos.Core.ErrorFeedWindowTest do
  use ExUnit.Case, async: false

  alias Compos.Core.ErrorFeed

  setup do
    ErrorFeed.install()
    :ok
  end

  test "a signature publishes once a window, and again in the next window" do
    sig = "storm #{System.unique_integer([:positive])}"

    assert ErrorFeed.first_in_window?(sig, 10_000)
    refute ErrorFeed.first_in_window?(sig, 10_001)
    refute ErrorFeed.first_in_window?(sig, 19_999)
    assert ErrorFeed.first_in_window?(sig, 20_000)
  end

  test "two signatures in one window both publish" do
    a = "a #{System.unique_integer([:positive])}"
    b = "b #{System.unique_integer([:positive])}"

    assert ErrorFeed.first_in_window?(a, 50_000)
    assert ErrorFeed.first_in_window?(b, 50_000)
  end
end
