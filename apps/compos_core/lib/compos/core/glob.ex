defmodule Compos.Core.Glob do
  @moduledoc """
  Expand a path pattern to the files it names.

  `*` matches within one name and `**` matches any depth of folders,
  none included. A wildcard never matches a name that starts with a dot,
  and `**` never enters a folder named in SKIP. Which folders to skip is
  the caller's decision; this module only walks.
  """

  # A link that points at a folder above itself makes `**` endless.
  @max_depth 64

  @doc "The files PATTERN names, sorted within each folder, shallow first."
  def files(pattern, skip \\ []) do
    segs = pattern |> Path.expand() |> Path.split() |> tl()
    walk("/", segs, MapSet.new(skip), 0)
  end

  defp walk(path, [], _skip, _depth) do
    if type(path) == :regular, do: [path], else: []
  end

  defp walk(_dir, _segs, _skip, depth) when depth > @max_depth, do: []

  # A folder is found by reading it: on a file the read fails at a third
  # of the cost of a type query, and a walk asks once for every entry.
  defp walk(dir, ["**" | rest] = segs, skip, depth) do
    case names(dir) do
      nil ->
        []

      names ->
        below =
          for name <- names,
              not MapSet.member?(skip, name),
              file <- walk(Path.join(dir, name), segs, skip, depth + 1),
              do: file

        walk(dir, rest, skip, depth) ++ below
    end
  end

  defp walk(dir, [seg | rest], skip, depth) do
    if String.contains?(seg, "*") do
      re = name_regex(seg)

      for name <- names(dir) || [],
          Regex.match?(re, name),
          file <- walk(Path.join(dir, name), rest, skip, depth + 1),
          do: file
    else
      walk(Path.join(dir, seg), rest, skip, depth + 1)
    end
  end

  # The type of what PATH names, a link followed.
  defp type(path) do
    case :file.read_file_info(path, [:raw]) do
      {:ok, info} -> elem(info, 2)
      {:error, _} -> nil
    end
  end

  # The names a wildcard can match: sorted, none with a leading dot. nil
  # when DIR is not a folder that can be read.
  defp names(dir) do
    case :file.list_dir(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&IO.chardata_to_string/1)
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()

      {:error, _} ->
        nil
    end
  end

  defp name_regex(seg) do
    body = seg |> String.split("*") |> Enum.map_join("[^/]*", &Regex.escape/1)
    Regex.compile!("^" <> body <> "$")
  end
end
