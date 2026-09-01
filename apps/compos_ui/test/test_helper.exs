# Stale checkpoints in the shared test home slow every catalog read; see
# apps/compos_core/test/test_helper.exs. Each app runs in its own VM, so each
# one clears the directory it would otherwise leave behind.
case Application.get_env(:compos_core, :home) do
  home when is_binary(home) -> File.rm_rf!(Path.join(home, "buffers"))
  _ -> :ok
end

# The chat transcript renders markdown through the page renderer, which
# needs the reader's installed grammars. Load the real ones read-only when
# they are there, the way apps/compos_core/test/test_helper.exs does; the
# tests otherwise exercise the Earmark fallback.
for name <- ["markdown", "markdown-inline"] do
  dir = Path.expand("~/.compos/grammars")
  lib = Path.join(dir, name <> if(:os.type() |> elem(1) == :darwin, do: ".dylib", else: ".so"))
  query = Path.join(dir, name <> "-highlights.scm")

  if File.exists?(lib) and File.exists?(query) do
    Compos.Core.TS.ts_load_grammar(name, lib, File.read!(query))
  end
end

ExUnit.start()

# UI agent fixtures must not create worktrees of the repository under test.
{:ok, _} =
  Compos.Core.Session.eval("(customize-set! 'agent-worktree-isolation #f)")
