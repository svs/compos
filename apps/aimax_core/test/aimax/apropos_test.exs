defmodule Aimax.AproposTest do
  @moduledoc """
  The catalog tests that Scheme cannot hold.

  The search, the entries and the cold start are Scheme policy and live in
  priv/tests/apropos-test.scm. Four tests stay here. Two read the Elixir
  registration maps directly. Two are red today, on the bundled backfill
  and the frozen Luna count, and a red test in the Scheme suite would hide
  the next real failure.
  """

  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  describe "the catalog" do
    test "the bundled backfill leaves no unknown metadata" do
      assert {:ok, "()"} =
               Session.eval("""
               (filter (lambda (e)
                         (and (equal? (plist-get e 'origin) "bundled")
                              (or (equal? (plist-get e 'domain) "unknown")
                                  (member "unknown" (plist-get e 'effects)))))
                       (catalog))
               """)
    end

    test "new bundled declarations cannot silently expand the Luna backfill" do
      # A new Scheme declaration must stamp itself. Change this frozen count
      # only after regenerating and reviewing the Luna artifact.
      assert eval!("""
             (length (filter (lambda (e)
                               (equal? (plist-get e 'metadata-source) "luna"))
                             (catalog)))
             """) == "653"

      assert Aimax.Core.CatalogBackfill.count() == 713
    end
  end

  describe "internal primitives" do
    test "docs cover the registration maps exactly, both ways" do
      for {prims, docs} <- [
            {Aimax.Scheme.Builtins.all(), Aimax.Scheme.Builtins.docs()},
            {Aimax.Core.SchemeAPI.primitives(), Aimax.Core.SchemeAPI.docs()}
          ] do
        assert Enum.sort(Map.keys(prims)) == Enum.sort(Map.keys(docs))
      end
    end

    test "every doc is written the house way: signature, dash, sentence" do
      all =
        Aimax.Scheme.Builtins.docs()
        |> Map.merge(Aimax.Core.SchemeAPI.docs())
        |> Map.merge(Aimax.Core.Session.docs())

      bad =
        Enum.reject(all, fn {name, doc} ->
          String.starts_with?(doc, "(#{name}") and String.contains?(doc, " — ")
        end)

      assert bad == []
    end
  end
end
