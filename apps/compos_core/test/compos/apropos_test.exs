defmodule Compos.AproposTest do
  @moduledoc """
  The two catalog tests that Scheme cannot hold.

  The search, the entries, the cold start and the metadata line are Scheme
  policy and live in priv/tests/apropos-test.scm. These two stay here: they
  read the Elixir registration maps, which have no Scheme surface.
  """

  use ExUnit.Case

  describe "internal primitives" do
    test "docs cover the registration maps exactly, both ways" do
      for {prims, docs} <- [
            {Compos.Scheme.Builtins.all(), Compos.Scheme.Builtins.docs()},
            {Compos.Core.SchemeAPI.primitives(), Compos.Core.SchemeAPI.docs()}
          ] do
        assert Enum.sort(Map.keys(prims)) == Enum.sort(Map.keys(docs))
      end
    end

    test "every doc is written the house way: signature, dash, sentence" do
      all =
        Compos.Scheme.Builtins.docs()
        |> Map.merge(Compos.Core.SchemeAPI.docs())
        |> Map.merge(Compos.Core.Session.docs())

      bad =
        Enum.reject(all, fn {name, doc} ->
          String.starts_with?(doc, "(#{name}") and String.contains?(doc, " — ")
        end)

      assert bad == []
    end
  end
end
