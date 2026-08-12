defmodule Aimax.Core.Git do
  @moduledoc """
  Git as mechanism: run the command, parse the bytes, return structured data.

  This module holds no policy. It does not know about buffers, windows, or
  modes. `priv/packages/git.scm` decides what a diff looks like and what `RET`
  does on a line. Parsers are mechanism, so the porcelain and unified-diff
  parsers live here.

  Every function is synchronous and returns `{:ok, value} | {:error, message}`.
  The Session must never block on git, so the `git-*` primitives run these
  functions in a supervised Task when the caller gives a callback.

  Two rules hold everywhere:

  * Always the argv list form. Never a shell string.
  * `stderr_to_stdout: false`. A parser must never read a warning as data.
    The error path runs the command a second time to collect the message.
  """

  @doc """
  The absolute path of the work tree that contains `dir`.

  Resolves from a subdirectory, like every git command.
  """
  def root(dir) do
    with {:ok, out} <- run(dir, ["rev-parse", "--show-toplevel"]) do
      {:ok, String.trim_trailing(out, "\n")}
    end
  end

  @doc """
  The work tree status as a list of

      %{path: p, orig_path: nil | p2, index: "M", worktree: "M"}

  `index` is the X column and `worktree` is the Y column of `git status`.
  Untracked files carry `"?"` in both. A rename or a copy fills `orig_path`.
  """
  def status(dir) do
    with {:ok, out} <- run(dir, ["status", "--porcelain=v1", "-z"]) do
      {:ok, parse_status(out)}
    end
  end

  @doc """
  A parsed unified diff: one entry per file, each with its hunks.

  Options:

  * `:base` — the ref to compare against. Defaults to `"HEAD"`. Pass `nil` to
    drop the ref and diff the work tree against the index.
  * `:path` — limit the diff to one path.
  * `:staged` — compare the index instead of the work tree.

  Each hunk keeps its raw `@@` header, because the diff buffer prints it.
  """
  def diff(dir, opts \\ []) do
    base = Keyword.get(opts, :base, "HEAD")
    path = Keyword.get(opts, :path)
    staged = Keyword.get(opts, :staged, false)

    args =
      ["diff", "--no-color", "--no-ext-diff", "-U3"] ++
        if(staged, do: ["--cached"], else: []) ++
        if(blank?(base), do: [], else: [base]) ++
        if(blank?(path), do: [], else: ["--", path])

    with {:ok, out} <- run(dir, args) do
      {:ok, parse_diff(out)}
    end
  end

  @doc """
  The last `n` commits as `%{sha, short_sha, author, date, subject}`.

  `date` is the author date in ISO 8601.
  """
  def log(dir, n) when is_integer(n) and n > 0 do
    args = ["log", "-n", Integer.to_string(n), "--format=%H%x00%an%x00%aI%x00%s", "-z"]

    with {:ok, out} <- run(dir, args) do
      {:ok, parse_log(out)}
    end
  end

  @doc "The raw text of one commit."
  def show(dir, ref), do: run(dir, ["show", "--no-color", "--no-ext-diff", ref])

  # --- running git -----------------------------------------------------------

  defp run(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: false) do
      {out, 0} -> {:ok, out}
      {_out, code} -> {:error, failure_message(dir, args, code)}
    end
  rescue
    e in ErlangError -> {:error, "git: #{inspect(e.original)} (#{dir})"}
    e in ArgumentError -> {:error, "git: #{Exception.message(e)} (#{dir})"}
  end

  # git wrote the reason to stderr and we deliberately did not read it. The
  # error path is rare, so pay for a second run to tell the user what broke.
  defp failure_message(dir, args, code) do
    case stderr_of(dir, args) do
      "" -> "git #{hd(args)} failed (exit #{code})"
      text -> text
    end
  end

  defp stderr_of(dir, args) do
    {out, _code} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out |> String.trim() |> first_line()
  rescue
    _ -> ""
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # --- status ----------------------------------------------------------------

  defp parse_status(out) do
    out
    |> String.split(<<0>>)
    |> Enum.reject(&(&1 == ""))
    |> consume_status([])
  end

  defp consume_status([], acc), do: Enum.reverse(acc)

  # `XY path`: X is the index column, Y is the work tree column. A rename or a
  # copy consumes TWO chunks — the new path first, the original path second.
  defp consume_status([<<x::binary-size(1), y::binary-size(1), " ", path::binary>> | rest], acc) do
    if x in ["R", "C"] or y in ["R", "C"] do
      case rest do
        [orig | rest2] -> consume_status(rest2, [entry(x, y, path, orig) | acc])
        [] -> consume_status([], [entry(x, y, path, nil) | acc])
      end
    else
      consume_status(rest, [entry(x, y, path, nil) | acc])
    end
  end

  defp consume_status([_ | rest], acc), do: consume_status(rest, acc)

  defp entry(x, y, path, orig), do: %{path: path, orig_path: orig, index: x, worktree: y}

  # --- unified diff ----------------------------------------------------------

  @hunk_header ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/
  @git_header ~r/^diff --git a\/(.*) b\/(.*)$/

  defp parse_diff(out) do
    out
    |> String.split("\n")
    |> parse_files([], nil)
  end

  defp parse_files([], files, cur), do: cur |> close_file(files) |> Enum.reverse()

  defp parse_files([line | rest], files, cur) do
    cond do
      String.starts_with?(line, "diff --git ") ->
        parse_files(rest, close_file(cur, files), open_file(line))

      # anything before the first `diff --git` is not ours to read
      is_nil(cur) ->
        parse_files(rest, files, nil)

      String.starts_with?(line, "--- ") ->
        parse_files(rest, files, %{cur | file_a: strip_ab(binary_part(line, 4, byte_size(line) - 4))})

      String.starts_with?(line, "+++ ") ->
        parse_files(rest, files, %{cur | file_b: strip_ab(binary_part(line, 4, byte_size(line) - 4))})

      String.starts_with?(line, "Binary files ") or String.starts_with?(line, "GIT binary patch") ->
        parse_files(rest, files, %{cur | binary?: true})

      String.starts_with?(line, "@@") ->
        parse_files(rest, files, open_hunk(cur, line))

      cur.hunks == [] ->
        # index, mode, and similarity headers sit between the paths and the
        # first hunk
        parse_files(rest, files, cur)

      true ->
        parse_files(rest, files, add_line(cur, line))
    end
  end

  defp open_file(line) do
    {a, b} =
      case Regex.run(@git_header, line) do
        [_, a, b] -> {a, b}
        _ -> {nil, nil}
      end

    %{file_a: a, file_b: b, binary?: false, hunks: []}
  end

  defp close_file(nil, files), do: files

  defp close_file(cur, files) do
    hunks = cur.hunks |> Enum.reverse() |> Enum.map(&close_hunk/1)
    [%{cur | hunks: hunks} | files]
  end

  defp close_hunk(h) do
    %{
      header: h.header,
      old_start: h.old_start,
      old_count: h.old_count,
      new_start: h.new_start,
      new_count: h.new_count,
      lines: Enum.reverse(h.lines)
    }
  end

  defp open_hunk(cur, line) do
    case Regex.run(@hunk_header, line) do
      [_ | caps] ->
        [old_start, old_count, new_start, new_count] = hunk_counts(caps)

        hunk = %{
          header: line,
          old_start: old_start,
          old_count: old_count,
          new_start: new_start,
          new_count: new_count,
          lines: [],
          rem_old: old_count,
          rem_new: new_count
        }

        %{cur | hunks: [hunk | cur.hunks]}

      nil ->
        cur
    end
  end

  # a missing count means one line
  defp hunk_counts(caps) do
    [os, oc, ns, nc] = Enum.map(0..3, fn i -> Enum.at(caps, i, "") end)
    [num(os, 0), num(oc, 1), num(ns, 0), num(nc, 1)]
  end

  defp num("", default), do: default
  defp num(nil, default), do: default
  defp num(s, _default), do: String.to_integer(s)

  defp add_line(cur, line) do
    [h | rest] = cur.hunks

    # the counts in the header say where the hunk ends. Trailing blanks and
    # the "\ No newline" marker fall outside it.
    if h.rem_old <= 0 and h.rem_new <= 0 do
      cur
    else
      case tag_line(line) do
        nil -> cur
        {tag, text} -> %{cur | hunks: [push_line(h, tag, text) | rest]}
      end
    end
  end

  defp tag_line(" " <> text), do: {:ctx, text}
  defp tag_line("+" <> text), do: {:add, text}
  defp tag_line("-" <> text), do: {:del, text}
  # git strips nothing, but editors and mail transports do: a bare empty line
  # inside a hunk is an empty context line
  defp tag_line(""), do: {:ctx, ""}
  defp tag_line(_), do: nil

  defp push_line(h, :ctx, text),
    do: %{h | lines: [{:ctx, text} | h.lines], rem_old: h.rem_old - 1, rem_new: h.rem_new - 1}

  defp push_line(h, :add, text),
    do: %{h | lines: [{:add, text} | h.lines], rem_new: h.rem_new - 1}

  defp push_line(h, :del, text),
    do: %{h | lines: [{:del, text} | h.lines], rem_old: h.rem_old - 1}

  defp strip_ab("a/" <> rest), do: rest
  defp strip_ab("b/" <> rest), do: rest
  defp strip_ab(path), do: path

  # --- log -------------------------------------------------------------------

  defp parse_log(out) do
    out
    |> String.split(<<0>>)
    |> Enum.map(&String.trim_leading(&1, "\n"))
    |> drop_trailing_empty()
    |> Enum.chunk_every(4, 4, :discard)
    |> Enum.map(fn [sha, author, date, subject] ->
      %{
        sha: sha,
        short_sha: short(sha),
        author: author,
        date: date,
        subject: subject
      }
    end)
  end

  defp drop_trailing_empty(list) do
    list |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
  end

  defp short(sha) when byte_size(sha) >= 7, do: binary_part(sha, 0, 7)
  defp short(sha), do: sha
end
