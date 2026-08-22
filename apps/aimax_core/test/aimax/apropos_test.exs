defmodule Aimax.AproposTest do
  @moduledoc """
  The catalog tests that Scheme cannot hold.

  The search, the entries and the cold start are Scheme policy and live in
  priv/tests/apropos-test.scm. Four tests stay here. Two read the Elixir
  registration maps directly. Two hold the metadata line across the whole
  catalog, which one package's Scheme test cannot see.
  """

  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  describe "the catalog" do
    test "an entry declares its metadata or admits it does not know" do
      # The catalog has two answers. A guessed third answer reaches the
      # permission policy, which is why there is no generator for one.
      assert {:ok, "()"} =
               Session.eval("""
               (filter (lambda (e)
                         (not (member (plist-get e 'metadata-source)
                                      '("declared" "unknown"))))
                       (catalog))
               """)
    end

    test "unstamped bundled declarations do not multiply" do
      # An unstamped entry reads "unknown", so the permission policy asks
      # before it acts. That is correct, and it is also a debt. A new
      # declaration stamps itself: lower this number, never raise it.
      assert eval!("""
             (length (filter (lambda (e)
                               (and (equal? (plist-get e 'origin) "bundled")
                                    (equal? (plist-get e 'metadata-source) "unknown")))
                             (catalog)))
             """) == "587"
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
