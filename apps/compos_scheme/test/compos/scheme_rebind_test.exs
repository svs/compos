defmodule Compos.SchemeRebindTest do
  @moduledoc """
  `Compos.Scheme.rebind_primitives/2`: what a host calls after a code reload.

  A primitive is an anonymous fun the host captured when it built the
  interpreter. Recompiling the module that defined the fun purges the version
  the fun came from, and calling it then raises "function #Function<...> is
  invalid, likely because it points to an old version of the code". Rebinding
  swaps every such fun for one from the version now loaded.

  The hard part is that the host's stdlib wraps its own primitives. Writing
  the primitive map straight into the global frame would put each primitive
  back over its wrapper and undo the stdlib.
  """

  use ExUnit.Case, async: true

  alias Compos.Scheme

  defp interp(answer) do
    Scheme.new(primitives: %{"host-answer" => fn [] -> answer end})
  end

  test "a primitive still bound under its own name takes the new fun" do
    interp = interp(1)
    assert {:ok, 1, _} = Scheme.eval_string(interp, "(host-answer)")

    interp = Scheme.rebind_primitives(interp, %{"host-answer" => fn [] -> 2 end})

    assert {:ok, 2, _} = Scheme.eval_string(interp, "(host-answer)")
  end

  test "a Scheme wrapper over a primitive survives the rebind" do
    interp = interp(1)
    {:ok, _, interp} = Scheme.eval_string(interp, "(define raw-answer host-answer)")
    {:ok, _, interp} = Scheme.eval_string(interp, "(define (host-answer) 99)")

    interp = Scheme.rebind_primitives(interp, %{"host-answer" => fn [] -> 2 end})

    assert {:ok, 99, _} = Scheme.eval_string(interp, "(host-answer)"),
           "the rebind put the primitive back over the wrapper"

    assert {:ok, 2, _} = Scheme.eval_string(interp, "(raw-answer)"),
           "the alias kept the old fun, which a purge would have killed"
  end

  test "a primitive the new version adds is bound" do
    interp = interp(1)

    interp =
      Scheme.rebind_primitives(interp, %{
        "host-answer" => fn [] -> 1 end,
        "host-extra" => fn [] -> 7 end
      })

    assert {:ok, 7, _} = Scheme.eval_string(interp, "(host-extra)")
  end

  test "a stale read cache in the caller does not resurrect an old binding" do
    # The host calls rebind from its own process, not from inside `exec`, so
    # its `:scheme_cache` still holds whatever it read last. Another process
    # then redefines the name. The walk writes back what it reads, so a stale
    # cached primitive goes over the wrapper the other process just defined.
    # Flush first: the global frame must live in the shared tier, as it does
    # after boot. A local frame reads from the store, never from the cache.
    interp = Scheme.flush(interp(1))
    Compos.Scheme.Env.fetch(interp.store, interp.global, "host-answer")

    Task.await(
      Task.async(fn ->
        {:ok, _, _} = Scheme.eval_string(interp, "(define (host-answer) 99)")
      end)
    )

    interp = Scheme.rebind_primitives(interp, %{"host-answer" => fn [] -> 2 end})

    assert {:ok, 99, _} = Scheme.eval_string(interp, "(host-answer)"),
           "the rebind read a stale cache and put the primitive back"
  end

  test "the builtins are rebound too" do
    interp = interp(1)
    interp = Scheme.rebind_primitives(interp, %{"host-answer" => fn [] -> 1 end})

    assert {:ok, 3, _} = Scheme.eval_string(interp, "(+ 1 2)")
    assert {:ok, "abc", _} = Scheme.eval_string(interp, ~s{(string-append "a" "bc")})
  end
end
