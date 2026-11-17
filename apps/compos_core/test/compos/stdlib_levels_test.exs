defmodule Compos.StdlibLevelsTest do
  @moduledoc """
  Core (priv/*.scm and scheme/packages) and the standard library (scheme/stdlib) are two
  levels of one load-path, core first. A file name in both means the stdlib
  copy never loads; a top-level define in both means whichever loads last
  wins. Either is a bug: each name lives at one level.
  """

  use ExUnit.Case, async: true

  defp root, do: Path.expand("../../../..", __DIR__)

  defp files("core") do
    Path.wildcard(Path.join([root(), "apps/compos_core/priv", "*.scm"])) ++ files("packages")
  end

  defp files(level) do
    Path.wildcard(Path.join([root(), "scheme", level, "**", "*.scm"]))
  end

  defp defines(paths) do
    for path <- paths,
        not String.ends_with?(path, "-test.scm"),
        [_, name] <- Regex.scan(~r/^\(define\s+\(?'?([^\s()]+)/m, File.read!(path)),
        reduce: %{} do
      acc -> Map.update(acc, name, [path], &[path | &1])
    end
  end

  test "no Scheme file name is in both core and scheme/stdlib" do
    core = files("core") |> Enum.map(&Path.basename/1) |> MapSet.new()
    std = files("stdlib") |> Enum.map(&Path.basename/1) |> MapSet.new()
    assert MapSet.size(std) > 50
    assert MapSet.intersection(core, std) |> Enum.sort() == []
  end

  test "no top-level define is in both core and scheme/stdlib" do
    core = defines(files("core"))
    std = defines(files("stdlib"))

    both =
      for {name, paths} <- core, Map.has_key?(std, name) do
        "#{name}: #{Enum.join(paths ++ std[name], ", ")}"
      end

    assert Enum.sort(both) == []
  end
end
