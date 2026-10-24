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

  @app_js Path.expand("../../../priv/static/app.js", __DIR__)

  defp encoder_script do
    src = File.read!(@app_js)
    [_, rest] = String.split(src, "const NAMED = {", parts: 2)
    [body, _] = String.split(rest, "const WHICH_KEY_MODIFIERS", parts: 2)
    "const NAMED = {" <> body
  end

  # Runs every case through keySpec, nativeTextKey and editingAfterKey. A
  # case is a key event plus `editable`: whether a contenteditable buffer
  # surface has focus, and `editing`: whether that surface is in the
  # editing state (the movement state is the default).
  defp run(cases) do
    script = """
    #{encoder_script()}
    const cases = #{Jason.encode!(cases)};
    const out = cases.map((c) => {
      globalThis.document = {
        documentElement: { classList: { contains: () => false } },
        querySelector: (s) => s === ".window.active .cap-pop" && c.completion ? {} : null,
        activeElement: c.editable
          ? { closest: (s) => (
              s === ".buf[contenteditable]" ||
              (s === ".window.active .buf[contenteditable]" && c.active !== false)
                ? {} : null) }
          : null
      };
      const e = Object.assign(
        { key: "", code: "", ctrlKey: false, altKey: false, shiftKey: false, metaKey: false },
        c.event
      );
      const editing = c.editing === true;
      return { spec: keySpec(e), native: nativeTextKey(e, editing),
               after: editingAfterKey(e, editing) };
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

  test "completion owns arrows and Enter while text still uses beforeinput" do
    keys = ~w(ArrowUp ArrowDown ArrowLeft ArrowRight Enter)
    results = run(for key <- keys, do: %{event: event(key, key), editable: true,
      editing: true, completion: true})
    assert Enum.all?(results, &(&1["native"] == false))
    [typing] = run([%{event: event("a", "KeyA"), editable: true,
      editing: true, completion: true}])
    assert typing["native"] == true
  end

  test "an inactive editable cannot swallow the selected list pane's keys" do
    results =
      run(
        for key <- ~w(ArrowUp ArrowDown ArrowLeft ArrowRight Enter Backspace a),
            do: %{event: event(key, key), editable: true, active: false, editing: true}
      )

    assert Enum.all?(results, &(&1["native"] == false))

    assert Enum.take(Enum.map(results, & &1["spec"]), 4) ==
             ["<up>", "<down>", "<left>", "<right>"]
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

      assert Map.take(left, ["spec", "native"]) == %{"spec" => "s-<left>", "native" => false}
      assert Map.take(right, ["spec", "native"]) == %{"spec" => "s-<right>", "native" => false}
    end

    test "Cmd-Left and Cmd-Right are the browser's own motion in the editing state; Cmd-Up and Cmd-Down stay keys" do
      results =
        run(
          for k <- ~w(ArrowLeft ArrowRight ArrowUp ArrowDown),
              do: %{event: event(k, k, [:metaKey]), editable: true, editing: true}
        )

      assert Enum.map(results, & &1["native"]) == [true, true, false, false]
    end

    test "the four Cmd-arrows travel as keys from a surface in the movement state" do
      results =
        run(
          for k <- ~w(ArrowLeft ArrowRight ArrowUp ArrowDown),
              do: %{event: event(k, k, [:metaKey]), editable: true}
        )

      assert results == [
               %{"spec" => "s-<left>", "native" => false, "after" => false},
               %{"spec" => "s-<right>", "native" => false, "after" => false},
               %{"spec" => "s-<up>", "native" => false, "after" => false},
               %{"spec" => "s-<down>", "native" => false, "after" => false}
             ]
    end

    test "a printable key, RET, a plain arrow and a chord enter the editing state" do
      results =
        run([
          %{event: event("a", "KeyA"), editable: true},
          %{event: event("Enter", "Enter"), editable: true},
          %{event: event("ArrowDown", "ArrowDown"), editable: true},
          %{event: event("x", "KeyX", [:ctrlKey]), editable: true},
          %{event: event("ArrowLeft", "ArrowLeft", [:metaKey, :shiftKey]), editable: true}
        ])

      assert Enum.map(results, & &1["after"]) == [true, true, true, true, true]
    end

    test "ESC and C-g return to the movement state" do
      [esc, cg] =
        run([
          %{event: event("Escape", "Escape"), editable: true, editing: true},
          %{event: event("g", "KeyG", [:ctrlKey]), editable: true, editing: true}
        ])

      assert esc["after"] == false
      assert cg["after"] == false
    end

    test "a modifier alone and a plain Cmd-arrow keep the state" do
      results =
        run([
          %{event: event("Shift", "ShiftLeft", [:shiftKey]), editable: true},
          %{event: event("Meta", "MetaLeft", [:metaKey]), editable: true, editing: true},
          %{event: event("ArrowUp", "ArrowUp", [:metaKey]), editable: true},
          %{event: event("ArrowRight", "ArrowRight", [:metaKey]), editable: true, editing: true}
        ])

      assert Enum.map(results, & &1["after"]) == [false, true, false, true]
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
      [plain] = run([%{event: event("ArrowLeft", "ArrowLeft"), editable: true}])
      assert plain["native"] == true
    end

    test "a Shift-arrow is the window motion until editing, and arms nothing" do
      [moving, editing] =
        run([
          %{event: event("ArrowLeft", "ArrowLeft", [:shiftKey]), editable: true, editing: false},
          %{event: event("ArrowLeft", "ArrowLeft", [:shiftKey]), editable: true, editing: true}
        ])

      assert moving["native"] == false
      assert moving["spec"] == "S-<left>"
      assert moving["after"] == false
      assert editing["native"] == true
      assert editing["after"] == true
    end

    test "PageDown and PageUp are keys on an editable surface" do
      [down, up] =
        run([
          %{event: event("PageDown", "PageDown"), editable: true},
          %{event: event("PageUp", "PageUp"), editable: true}
        ])

      assert Map.take(down, ["spec", "native"]) == %{"spec" => "<next>", "native" => false}
      assert Map.take(up, ["spec", "native"]) == %{"spec" => "<prior>", "native" => false}
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
