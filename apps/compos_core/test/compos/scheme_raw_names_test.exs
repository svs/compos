defmodule Compos.SchemeRawNamesTest do
  @moduledoc """
  Every raw name the editor calls is a primitive Elixir registers.

  Scheme used to make these names itself, with `(define raw-x x)` above the
  wrapper, and one whole-file reload of editor.scm could point a wrapper at
  itself. Elixir owns them now, so the primitive stays reachable however
  the Scheme world is reloaded.
  """

  use ExUnit.Case

  alias Compos.Core.Session
  alias Compos.Core.SchemeRawNames

  @lane {:raw_names, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  alias Compos.Scheme.Prim

  test "add/1 gives a raw name the same fun as the primitive it names, and a doc" do
    fun = fn [] -> :void end
    added = SchemeRawNames.add(%{{"define-command", "(define-command ...) — define."} => fun})

    assert Prim.funs(added)["define-command--raw"] == fun
    assert Prim.docs(added)["define-command--raw"] =~ "define-command"
  end

  # Each module holds its own primitives only, so the shared list must skip
  # every name whose target this map does not have.
  test "add/1 skips a raw name whose target is not in the map" do
    added =
      SchemeRawNames.add(%{
        {"define-command", "(define-command ...) — define."} => fn [] -> :void end
      })

    refute Map.has_key?(Prim.funs(added), "raw-buffer-create")
  end

  test "SchemeAPI registers the raw name of every primitive it wraps" do
    primitives = Compos.Core.SchemeAPI.primitives()
    docs = Compos.Core.SchemeAPI.docs()

    for {raw, target} <- SchemeRawNames.wrapped(), Map.has_key?(primitives, target) do
      assert Map.fetch!(primitives, raw) == Map.fetch!(primitives, target),
             "#{raw} is not the #{target} fun"

      assert is_binary(docs[raw]), "#{raw} has no primitive doc"
    end
  end

  # The end of the chain: Session's own primitives are private, and a name
  # that no module registers is an unbound variable in the live editor.
  @tag timeout: 120_000
  test "the live editor binds every raw name to a documented primitive" do
    for {raw, target} <- SchemeRawNames.wrapped() do
      assert eval!("(procedure? #{raw})") == "#t",
             "#{raw} (for #{target}) is not bound in the live editor"

      assert eval!(~s{(string? (primitive-doc "#{raw}"))}) == "#t",
             "#{raw} is not documented as a primitive"
    end
  end

  # A capture left behind in Scheme is the bug this module removes.
  test "no bundled Scheme file captures a raw name" do
    priv = Application.app_dir(:compos_core, "priv")

    packages = Path.join(Compos.Core.project_dir(), "scheme/packages")
    apps = Path.join(Compos.Core.project_dir(), "scheme/apps")

    src =
      (Path.wildcard(Path.join(priv, "*.scm")) ++
         Path.wildcard(Path.join(packages, "**/*.scm")) ++
         Path.wildcard(Path.join(apps, "**/*.scm")))
      |> Enum.map_join("\n", &File.read!/1)

    for {raw, target} <- SchemeRawNames.wrapped() do
      refute String.contains?(src, "(define #{raw} #{target})"),
             "#{raw} is captured in Scheme; Elixir registers it"

      refute String.contains?(src, "(alias-once! '#{raw} '#{target})"),
             "#{raw} is captured in Scheme; Elixir registers it"
    end
  end
end
