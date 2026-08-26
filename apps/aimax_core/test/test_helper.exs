# A checkpoint outlives the run that wrote it, so the test home fills up.
# Every test that reads the buffer catalog then walks all of them: 1438 stale
# checkpoints took one 7-test file from 0.6s to 140s. Start each run empty.
File.rm_rf!(Path.join(Application.get_env(:aimax_core, :home), "buffers"))

# The same failure, one directory over. A leaked fixture outlives its run and
# fills the system temp directory. The file prompt lists that directory and
# annotates every entry, so 5558 entries cost 2.1s on the :ui lane, per
# keystroke that changes the directory. Sweep our own fixtures at the start.
#
# Two guards keep this safe: the prefix list names test fixtures only, never
# a directory the daemon owns, and the age floor spares anything recent, so
# the four parallel partitions cannot delete each other's live fixtures.
defmodule Aimax.TestTmp do
  @prefixes ~w(nm-stub- aimax-wt- chat-flat- chat-cxs- chat-revive-)
  @max_age_s 3600

  def sweep do
    tmp = System.tmp_dir!()
    now = System.os_time(:second)

    for name <- File.ls!(tmp),
        String.starts_with?(name, @prefixes),
        path = Path.join(tmp, name),
        stale?(path, now) do
      File.rm_rf(path)
    end
  end

  defp stale?(path, now) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> now - mtime > @max_age_s
      _ -> false
    end
  end
end

Aimax.TestTmp.sweep()

# A tree-sitter grammar is a compiled artifact, not a fixture, so a test
# that needs one is excluded where it is missing rather than passing on an
# empty answer. The run then says "excluded", which a silent skip never
# does. Grammars live in the reader's home; a test home has none, so load
# the real ones read-only when they are there.
markdown_grammar? =
  Enum.all?(["markdown", "markdown-inline"], fn name ->
    dir = Path.expand("~/.aimax/grammars")
    lib = Path.join(dir, name <> if(:os.type() |> elem(1) == :darwin, do: ".dylib", else: ".so"))
    query = Path.join(dir, name <> "-highlights.scm")

    File.exists?(lib) and File.exists?(query) and
      Aimax.Core.TS.ts_load_grammar(name, lib, File.read!(query)) == "ok"
  end)

unless markdown_grammar? do
  ExUnit.configure(exclude: [:markdown_grammar])
end

ExUnit.start()

# Most agent tests exercise chat behavior against this repository checkout.
# Disable automatic checkout creation unless a test covers worktree policy.
{:ok, _} =
  Aimax.Core.Session.eval("(customize-set! 'agent-worktree-isolation #f)")
