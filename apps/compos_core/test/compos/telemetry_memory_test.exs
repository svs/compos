defmodule Compos.Core.TelemetryMemoryTest do
  use ExUnit.Case, async: false

  alias Compos.Core.Telemetry

  test "a browser memory row becomes a sample of its frame, and other rows do not" do
    frame = "f-mem-#{System.unique_integer([:positive])}"
    owner = "frame " <> frame

    Telemetry.browser(
      [
        %{"k" => "push", "l" => "key a", "ms" => 3, "t" => 1},
        %{"k" => "memory", "l" => "memory", "t" => 1000,
          "mem" => %{"heap" => 120, "total" => 200, "limit" => 4096, "nodes" => 5000,
                     "iframes" => 2, "canvases" => 1}},
        %{"k" => "memory", "l" => "memory", "t" => 61_000,
          "mem" => %{"heap" => nil, "nodes" => 5100, "iframes" => 2, "canvases" => 1}}
      ],
      frame
    )

    samples = Map.fetch!(Telemetry.memory(), owner)
    assert [first, second] = samples
    assert first.heap_mb == 120 and first.nodes == 5000 and first.time_ms == 1000
    assert second.heap_mb == nil and second.nodes == 5100
  end

  test "a frame keeps at most one day of samples" do
    frame = "f-cap-#{System.unique_integer([:positive])}"

    rows = for t <- 1..1445, do: %{"k" => "memory", "t" => t, "mem" => %{"heap" => t}}
    Telemetry.browser(rows, frame)

    samples = Map.fetch!(Telemetry.memory(), "frame " <> frame)
    assert length(samples) == 1440
    assert hd(samples).time_ms == 6
  end
end
