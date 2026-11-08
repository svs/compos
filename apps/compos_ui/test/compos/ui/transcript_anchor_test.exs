defmodule Compos.Ui.TranscriptAnchorTest do
  @moduledoc """
  The BlockFollow hook's `lastVisible`, run as the code it is.

  The hook names the block the reader last saw, so a server update can put
  them back on it. It found that block by measuring every block in the
  transcript. Each measurement flushes layout, so one scroll event on a
  long transcript cost one layout per block: the web process stopped
  answering and the window read as dead. The search must cost the same
  whatever the transcript holds.
  """

  use ExUnit.Case, async: true

  @app_js Path.expand("../../../priv/static/app.js", __DIR__)

  defp last_visible_source do
    src = File.read!(@app_js)
    [_, rest] = String.split(src, "this.lastVisible = () => {", parts: 2)
    [body, _] = String.split(rest, "\n        };", parts: 2)
    "const lastVisible = () => {" <> body <> "\n};"
  end

  # A scroller 500px tall over COUNT blocks of 100px, scrolled to the end,
  # so the last five blocks are the visible ones. The stub counts every
  # measurement, which is the cost the reader pays.
  defp run(count) do
    script = """
    let measurements = 0;
    const HEIGHT = 100, VIEW = 500, COUNT = #{count};
    const firstVisible = COUNT - VIEW / HEIGHT;

    const rect = (top, bottom) => {
      measurements += 1;
      return { top: top, bottom: bottom, left: 0, right: 800, width: 800,
               height: bottom - top };
    };

    const blocks = [];
    for (let i = 0; i < COUNT; i++) {
      const top = (i - firstVisible) * HEIGHT;
      const block = {
        dataset: { index: String(i) },
        top: top,
        bottom: top + HEIGHT,
        getBoundingClientRect: () => rect(top, top + HEIGHT)
      };
      block.closest = () => block;
      blocks.push(block);
    }

    const scroller = {
      getBoundingClientRect: () => rect(0, VIEW),
      querySelectorAll: () => blocks,
      contains: () => true
    };

    globalThis.window = { innerHeight: 900 };
    globalThis.document = {
      elementFromPoint: (x, y) =>
        blocks.find((b) => b.top <= y && y < b.bottom) || null
    };

    // the ui zoom is 1: a rect and a scrollTop count the same px
    const self = { scroller: scroller, scale: () => 1 };
    #{last_visible_source() |> String.replace("this.scroller", "self.scroller") |> String.replace("this.scale", "self.scale")}

    const found = lastVisible();
    process.stdout.write(JSON.stringify({ found: found, measurements: measurements }));
    """

    path =
      Path.join(
        System.tmp_dir!(),
        "compos-anchor-#{System.unique_integer([:positive])}.js"
      )

    File.write!(path, script)

    try do
      {out, 0} = System.cmd("node", [path], stderr_to_stdout: true)
      Jason.decode!(out)
    after
      File.rm(path)
    end
  end

  test "the search names the last visible block" do
    assert %{"found" => %{"index" => 39, "offset" => 400}} = run(40)
  end

  test "the cost does not follow the block count" do
    small = run(20)
    large = run(5_000)

    assert small["found"]["index"] == 19
    assert large["found"]["index"] == 4_999

    # a per-block measurement would make this 5_000 against 20
    assert large["measurements"] == small["measurements"]
    assert large["measurements"] <= 4
  end
end
