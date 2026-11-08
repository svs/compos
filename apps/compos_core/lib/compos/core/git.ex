defmodule Compos.Core.Git do
  @moduledoc """
  Git as mechanism: run the command, parse the bytes, return structured data.

  This module holds no policy. It does not know about buffers, windows, or
  modes. `scheme/packages/git.scm` decides what a diff looks like and what `RET`
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
  Where `dir` sits inside its work tree, as a relative path with a trailing
  slash — `"lib/web/"`, or `""` at the root.

  This is the scope of a diff. It has to come from git rather than from
  string arithmetic on `root`: the root is a resolved real path and the
  directory the reader is in may reach it through a symlink.
  """
  def prefix(dir) do
    with {:ok, out} <- run(dir, ["rev-parse", "--show-prefix"]) do
      {:ok, String.trim_trailing(out, "\n")}
    end
  end

  @doc """
  The work tree status as a list of

      %{path: p, orig_path: nil | p2, index: "M", worktree: "M"}

  `index` is the X column and `worktree` is the Y column of `git status`.
  Untracked files carry `"?"` in both. A rename or a copy fills `orig_path`.
  """
  def status(dir, path \\ nil) do
    args = ["status", "--porcelain=v1", "-z"] ++ pathspec(path)

    with {:ok, out} <- run(dir, args) do
      {:ok, parse_status(out)}
    end
  end

  # a pathspec scopes every read to one subtree: the diff you asked for is
  # the directory you are looking at, not the whole repository
  defp pathspec(path), do: if(blank?(path), do: [], else: ["--", path])

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
        pathspec(path)

    with {:ok, out} <- run(dir, args) do
      {:ok, parse_diff(out)}
    end
  end

  @doc """
  The last `n` commits as `%{sha, short_sha, author, date, subject}`.

  `date` is the author date in ISO 8601. With a `path`, only the commits
  that touched it.
  """
  def log(dir, n, path \\ nil) when is_integer(n) and n > 0 do
    args =
      ["log", "-n", Integer.to_string(n), "--format=%H%x00%an%x00%aI%x00%s", "-z"] ++
        pathspec(path)

    with {:ok, out} <- run(dir, args) do
      {:ok, parse_log(out)}
    end
  end

  @doc "Stage one path in the index."
  def stage_file(dir, path), do: run(dir, ["add", "--", path])

  @doc "Apply one unified patch to the index."
  def stage_patch(dir, patch) when is_binary(patch) do
    path =
      Path.join(
        System.tmp_dir!(),
        "compos-stage-#{System.unique_integer([:positive, :monotonic])}.diff"
      )

    try do
      with :ok <- File.write(path, patch) do
        run(dir, ["apply", "--cached", "--whitespace=nowarn", path])
      end
    after
      File.rm(path)
    end
  end

  @doc "The raw text of one commit."
  def show(dir, ref), do: run(dir, ["show", "--no-color", "--no-ext-diff", ref])

  @doc """
  Parse unified-diff text that did not come from `diff/2`.

  diff-mode's buffer text IS the unified diff, and the renderer reads the
  same bytes the reader sees. It parses them with this, so the card view
  and the plain view can never disagree.
  """
  def parse(text) when is_binary(text), do: parse_diff(text)

  # --- running git -----------------------------------------------------------

  # stderr goes to /dev/null: "not a git repository" is an answer here, and
  # without this every such probe wrote a fatal: line into the daemon log.
  # A failure reads the reason with a second run (failure_message/3).
  defp run(dir, args) do
    with :ok <- Compos.Core.SpawnDir.check(dir, "git #{hd(args)}") do
      case System.cmd("/bin/sh", ["-c", ~s(exec git "$@" 2>/dev/null), "git" | args], cd: dir) do
        {out, 0} -> {:ok, out}
        {_out, code} -> {:error, failure_message(dir, args, code)}
      end
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


    @block_query "(block) @block"
  @file_query """
  (old_file (filename) @old)
  (new_file (filename) @new)
  (command (filename) @command_path)
  (hunk) @hunk
  """
  @hunk_location_query "(location) @location"
  @hunk_range_query "(location (linerange) @range)"
  @hunk_add_query "(addition) @add"
  @hunk_del_query "(deletion) @del"
  @hunk_change_query "(change) @change"
  @hunk_context_query "(context) @ctx"

  defp parse_diff(out) do
    Compos.Core.TS.ts_query_nif("diff", out, @block_query)
    |> Enum.filter(fn {capture, _, _} -> capture == "block" end)
    |> Enum.map(fn {_, start, stop} ->
      parse_block(binary_part(out, start, stop - start), start)
    end)
  end

  defp parse_block(block, base) do
    captures = Compos.Core.TS.ts_query_nif("diff", block, @file_query)
    old_file = first_capture_text(block, captures, "old")
    new_file = first_capture_text(block, captures, "new")
    command_paths =
      first_capture_text(block, captures, "command_path")
      |> case do
        nil -> []
        text -> String.split(text)
      end

    {command_old, command_new} =
      case command_paths do
        [a, b | _] -> {a, b}
        [a] -> {a, a}
        _ -> {nil, nil}
      end

    hunk_ranges =
      captures
      |> Enum.filter(fn {capture, _, _} -> capture == "hunk" end)
      |> Enum.map(fn {_, start, stop} -> {start, stop} end)

    patch_head =
      case hunk_ranges do
        [{start, _} | _] -> binary_part(block, 0, start)
        [] -> block
      end

    hunks =
      Enum.map(hunk_ranges, fn {start, stop} ->
        raw = binary_part(block, start, stop - start)
        parse_ts_hunk(raw, base + start)
      end)

    end_byte =
      case List.last(hunks) do
        nil -> base + byte_size(block)
        hunk -> hunk.end_byte
      end

    %{
      file_a: strip_ab(old_file || command_old),
      file_b: strip_ab(new_file || command_new),
      binary?: false,
      patch_head: patch_head,
      start_byte: base,
      end_byte: end_byte,
      hunks: hunks
    }
  end

  defp parse_ts_hunk(raw, start_byte) do
    location_captures = Compos.Core.TS.ts_query_nif("diff", raw, @hunk_location_query)
    range_captures = Compos.Core.TS.ts_query_nif("diff", raw, @hunk_range_query)
    captures =
      Enum.flat_map(
        [
          @hunk_add_query,
          @hunk_del_query,
          @hunk_change_query,
          @hunk_context_query
        ],
        &Compos.Core.TS.ts_query_nif("diff", raw, &1)
      )
    header = first_capture_text(raw, location_captures, "location") || ""
    ranges = capture_texts(raw, range_captures, "range")
    {old_start, old_count} = parse_linerange(Enum.at(ranges, 0, "-0,0"))
    {new_start, new_count} = parse_linerange(Enum.at(ranges, 1, "+0,0"))

    lines =
      captures
      |> Enum.filter(fn {capture, _, _} -> capture in ["add", "del", "change", "ctx"] end)
      |> Enum.sort_by(fn {_, start, _} -> start end)
      |> Enum.map(fn
        {"add", start, stop} -> {:add, change_text(raw, start, stop)}
        {"del", start, stop} -> {:del, change_text(raw, start, stop)}
        {"change", start, stop} -> {:add, change_text(raw, start, stop)}
        {"ctx", start, stop} -> {:ctx, change_text(raw, start, stop)}
      end)

    structural_stop =
      (location_captures ++ range_captures ++ captures)
      |> Enum.map(fn {_, _, stop} -> stop end)
      |> Enum.max(fn -> byte_size(raw) end)

    %{
      header: header,
      old_start: old_start,
      old_count: old_count,
      new_start: new_start,
      new_count: new_count,
      lines: lines,
      patch: header <> "\n" <> Enum.map_join(lines, "", &patch_line/1),
      start_byte: start_byte,
      end_byte: start_byte + structural_stop
    }
  end

  defp first_capture_text(text, captures, name) do
    case Enum.find(captures, fn {capture, _, _} -> capture == name end) do
      {_, start, stop} -> binary_part(text, start, stop - start)
      nil -> nil
    end
  end

  defp capture_texts(text, captures, name) do
    for {^name, start, stop} <- captures, do: binary_part(text, start, stop - start)
  end

  defp parse_linerange(<<_sign::binary-size(1), rest::binary>>) do
    case String.split(rest, ",", parts: 2) do
      [start, count] -> {String.to_integer(start), String.to_integer(count)}
      [start] -> {String.to_integer(start), 1}
    end
  end

  defp patch_line({:add, text}), do: "+" <> text <> "\n"
  defp patch_line({:del, text}), do: "-" <> text <> "\n"
  defp patch_line({:ctx, text}), do: " " <> text <> "\n"

  defp change_text(text, start, stop) when stop > start do
    line = binary_part(text, start, stop - start)
    binary_part(line, 1, byte_size(line) - 1)
  end

  defp change_text(_text, _start, _stop), do: ""

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
