# Stale checkpoints in the shared test home slow every catalog read; see
# apps/compos_core/test/test_helper.exs. Each app runs in its own VM, so each
# one clears the directory it would otherwise leave behind.
case Application.get_env(:compos_core, :home) do
  home when is_binary(home) -> File.rm_rf!(Path.join(home, "buffers"))
  _ -> :ok
end

ExUnit.start()

# UI agent fixtures must not create worktrees of the repository under test.
{:ok, _} =
  Compos.Core.Session.eval("(customize-set! 'agent-worktree-isolation #f)")
