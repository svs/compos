defmodule Compos.Ui.KeySpecTest do
  @moduledoc """
  The client key encoder, run as the code it is. The test cuts the
  `baseKey`, `keySpec` and `nativeTextKey` functions out of the layout
  script and runs them under node with synthetic key events. The claim on
  a Cmd chord and the native-text gate are policy the daemon never sees:
  a key the client drops never reaches KeyDispatch, so this is the only
  place that proves the client sends it.
  """

  use ExUnit.Case, async: true

  @layouts Path.expand("../../../lib/compos/ui/layouts.ex", __DIR__)

  defp encoder_script do
    src = File.read!(@layouts)
    [_, rest] = String.split(src, "const NAMED = {", parts: 2)
    [body, _] = String.split(rest, "const WHICH_KEY_MODIFIERS", parts: 2)
    "const NAMED = {" <> body
  end

  # Runs every case through keySpec and nativeTextKey. A case is a key
  # event plus `editable`: whether a contenteditable buffer surface has
  # focus.
  defp run(cases) do
    script = """
    #{encoder_script()}
    const cases = #{Jason.encode!(cases)};
    const out = cases.map((c) => {
      globalThis.document = {
        activeElement: c.editable
          ? { closest: (s) => (s === ".buf[contenteditable]" ? {} : null) }
          : null
      };
      const e = Object.assign(
        { key: "", code: "", ctrlKey: false, altKey: false, shiftKey: false, metaKey: false },
        c.event
      );
      return { spec: keySpec(e), native: nativeTextKey(e) };
    });
    process.stdout.write(JSON.stringify(out));
    """

    path =
      Path.join(
        System.tmp_dir!(),
        "compos-key-spec-#{System.unique_integer([:positive])}.js"
      )

    File.write!(path, script)

    try do
      {out, 0} = System.cmd("node", [path], stderr_to_stdout: true)
      Jason.decode!(out)
    after
      File.rm(path)
    end
  end

  defp event(key, code, mods \\ []) do
    Map.merge(%{key: key, code: code}, Map.new(mods, &{&1, true}))
  end

  describe "a Cmd-arrow travels as a key" do
    test "Cmd-Up and Cmd-Down encode as s-<up> and s-<down>" do
      [up, down] =
        run([
          %{event: event("ArrowUp", "ArrowUp", [:metaKey])},
          %{event: event("ArrowDown", "ArrowDown", [:metaKey])}
        ])

      assert up["spec"] == "s-<up>"
      assert down["spec"] == "s-<down>"
    end

    test "Cmd-Left and Cmd-Right are keys outside an editable surface" do
      [left, right] =
        run([
          %{event: event("ArrowLeft", "ArrowLeft", [:metaKey])},
          %{event: event("ArrowRight", "ArrowRight", [:metaKey])}
        ])

      assert left == %{"spec" => "s-<left>", "native" => false}
      assert right == %{"spec" => "s-<right>", "native" => false}
    end

    test "Cmd-Left and Cmd-Right are the browser's line start and end on an editable surface" do
      [left, right] =
        run([
          %{event: event("ArrowLeft", "ArrowLeft", [:metaKey]), editable: true},
          %{event: event("ArrowRight", "ArrowRight", [:metaKey]), editable: true}
        ])

      assert left["native"] == true
      assert right["native"] == true
    end

    test "Cmd-Shift-Left and Cmd-Shift-Right encode as s-S-<left> and s-S-<right>" do
      [left, right] =
        run([
          %{event: event("ArrowLeft", "ArrowLeft", [:metaKey, :shiftKey])},
          %{event: event("ArrowRight", "ArrowRight", [:metaKey, :shiftKey])}
        ])

      assert left["spec"] == "s-S-<left>"
      assert right["spec"] == "s-S-<right>"
    end

    test "a plain arrow on an editable surface is native motion" do
      [plain, shifted] =
        run([
          %{event: event("ArrowLeft", "ArrowLeft"), editable: true},
          %{event: event("ArrowLeft", "ArrowLeft", [:shiftKey]), editable: true}
        ])

      assert plain["native"] == true
      assert shifted["native"] == true
    end
  end

  describe "the Cmd claim" do
    test "Cmd-Enter travels as s-RET" do
      [ret] = run([%{event: event("Enter", "Enter", [:metaKey])}])
      assert ret["spec"] == "s-RET"
    end

    test "Cmd-Shift-= reads its character from the physical key" do
      [plus] = run([%{event: event("=", "Equal", [:metaKey, :shiftKey])}])
      assert plus["spec"] == "s-+"
    end

    test "a Cmd chord the editor does not claim stays with the browser" do
      [c, v] =
        run([
          %{event: event("c", "KeyC", [:metaKey])},
          %{event: event("v", "KeyV", [:metaKey])}
        ])

      assert c["spec"] == nil
      assert v["spec"] == nil
    end
  end
end
