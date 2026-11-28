defmodule Compos.SchemeSuite do
  @moduledoc """
  The bridge that runs a Scheme test suite under ExUnit.

  There are two suites, as in Emacs. The kernel's tests live in
  priv/tests (`:core`). A package's tests live beside it, as
  scheme/packages/NAME-test.scm or NAME-test.scm inside a package's own
  directory (`:packages`). Each suite has its own test module; the default
  `mix test` runs the kernel suite only.

  One eval per test, so a test that raises fails alone and the rest still
  run.
  """

  alias Compos.Core.Session

  # The suite runs on its OWN lane, never :ui.
  #
  # wait-until holds the lane it runs on, and the editor delivers its
  # work on :ui — an on-change hook, an LSP status, a debounced redraw.
  # A suite that holds :ui blocks the very deliveries its tests wait for,
  # and they time out looking exactly like a slow server. Off :ui they
  # land in milliseconds.
  @lane {:scheme_suite, __MODULE__}

  def eval!(code) do
    {:ok, out} = eval(code)
    out
  end

  # a test that hangs is that test's failure, and the tests after it still run
  def eval(code) do
    Session.eval(code, nil, 30_000, @lane)
  catch
    :exit, reason -> {:error, "timed out: #{inspect(reason, limit: 3)}"}
  end

  @doc "The Scheme that loads KIND's suite once."
  def loader(:core), do: "(load-tests-once!)"
  def loader(:packages), do: "(load-package-tests-once!)"

  @doc "The files of KIND matched by SCHEME_TESTS, or all of them when unset."
  def active_files(kind) do
    case System.get_env("SCHEME_TESTS") do
      nil ->
        files(kind)

      words ->
        words = Enum.map(String.split(words, ",", trim: true), &String.trim/1)
        Enum.filter(files(kind), fn path -> Enum.any?(words, &String.contains?(Path.basename(path), &1)) end)
    end
  end

  @doc "Every test name the loaded suites registered."
  def names(kind) do
    load_expr =
      case System.get_env("SCHEME_TESTS") do
        nil ->
          loader(kind)

        _ ->
          paths = Enum.map_join(active_files(kind), " ", &inspect/1)
          "(load-test-files! (list #{paths}))"
      end

    eval!("(begin #{load_expr} (test-names))")
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(" ", trim: true)
  end

  @doc "The test files of KIND on disk."
  def files(:core), do: Path.wildcard(Path.join(core_dir(), "*.scm"))

  # the package suite spans the checkout, the standard repo and every
  # loaded community clone: Scheme's test-files knows them all
  def files(:packages) do
    case eval("(test-files 'packages)") do
      {:ok, out} -> Regex.scan(~r/"([^"]+)"/, out) |> Enum.map(fn [_, path] -> path end)
      _ -> []
    end
  end

  def core_dir, do: Path.join(:code.priv_dir(:compos_core), "tests")
  def package_dir, do: Path.join(Compos.Core.project_dir(), "scheme/packages")
  def apps_dir, do: Path.join(Compos.Core.project_dir(), "scheme/apps")

  @doc "The deftest names a file declares, read from the file."
  def declared(path) do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(path))
    |> Enum.map(fn [_, name] -> name end)
  end

  @doc "The names among FOUND that files of KIND declare."
  def own(found, kind) do
    declared = for path <- files(kind), name <- declared(path), into: MapSet.new(), do: name
    Enum.filter(found, &MapSet.member?(declared, &1))
  end

  @doc """
  The names SCHEME_TESTS selects: every test in a file of KIND whose name
  contains the word; a comma separates several words.

      SCHEME_TESTS=morg mix test test/compos/scheme_suite_test.exs
  """
  def selected(names, kind) do
    case System.get_env("SCHEME_TESTS") do
      nil ->
        names

      words ->
        words = Enum.map(String.split(words, ","), &String.trim/1)

        wanted =
          for path <- files(kind),
              Enum.any?(words, &String.contains?(Path.basename(path), &1)),
              name <- declared(path),
              do: name

        Enum.filter(names, &(&1 in wanted))
    end
  end

  @doc "The helpers two test files of the given kinds both define."
  def clashes(kinds) do
    owners =
      for kind <- kinds,
          path <- files(kind),
          [_, name] <- Regex.scan(~r/^\(define \(([^\s)]+)/m, File.read!(path)),
          reduce: %{} do
        acc -> Map.update(acc, name, [Path.basename(path)], &[Path.basename(path) | &1])
      end

    for {name, files} <- owners, length(Enum.uniq(files)) > 1, do: {name, files}
  end

  @doc "Every declared test of KIND that did not register."
  def missing(kind, found) do
    for path <- active_files(kind),
        name <- declared(path),
        name not in found,
        do: "#{Path.basename(path)}: #{name}"
  end

  @doc "Run NAMES in Scheme batches (falling back to 1-by-1 on timeout); answers failures and prints times on SCHEME_TIMES."
  def run(names) do
    want_times = System.get_env("SCHEME_TIMES") != nil

    {failures, times} =
      names
      |> Enum.chunk_every(50)
      |> Enum.reduce({[], []}, fn chunk, {fails, times} ->
        syms = Enum.map_join(chunk, " ", & &1)
        flag = if want_times, do: "#t", else: "#f"

        case eval("(run-tests-batch '(#{syms}) #{flag})") do
          {:ok, "()"}
          when not want_times ->
            {fails, times}

          {:ok, out} ->
            {chunk_fails, chunk_times} = parse_batch(out, want_times)
            {Enum.reverse(chunk_fails, fails), Enum.reverse(chunk_times, times)}

          {:error, _} ->
            # A batch timed out or crashed the process: re-run its tests one by one to isolate the offender.
            Enum.reduce(chunk, {fails, times}, fn name, {f_acc, t_acc} ->
              {us, result} = :timer.tc(fn -> eval("(run-test '#{name})") end)
              reduced = reduce(name, result)
              {if(reduced, do: [reduced | f_acc], else: f_acc), [{div(us, 1000), name} | t_acc]}
            end)
        end
      end)

    # SCHEME_TIMES=1 prints the slowest tests, for work on the editor's cost;
    # SCHEME_TIMES=all prints every test that ran
    if want_times do
      times
      |> Enum.sort(:desc)
      |> Enum.take(if System.get_env("SCHEME_TIMES") == "all", do: length(times), else: 25)
      |> Enum.each(fn {ms, name} -> IO.puts("  #{String.pad_leading(to_string(ms), 6)}ms  #{name}") end)
    end

    Enum.reverse(failures)
  end

  defp parse_batch(out, want_times) do
    case Compos.Scheme.Reader.read_all(out) do
      [parsed] ->
        if want_times do
          [raw_fails, raw_times] = parsed
          {Enum.map(raw_fails, &format_batch_fail/1),
           Enum.map(raw_times, fn [ms, {:sym, name}] -> {ms, name} end)}
        else
          {Enum.map(parsed, &format_batch_fail/1), []}
        end

      _ ->
        {["  <batch parse error>\n      #{out}"], []}
    end
  end

  defp format_batch_fail([{:sym, name}, {:sym, "error"}, msg]),
    do: "  #{name}\n      raised: #{msg}"

  defp format_batch_fail([{:sym, name}, {:sym, "fail"}, msgs]),
    do: "  #{name}\n      #{Compos.Scheme.Printer.print(msgs)}"

  # "()" is a pass. Anything else is the test's own report, or the eval
  # died — which is a failure of that test and not of this one.
  defp reduce(_name, {:ok, "()"}), do: nil
  defp reduce(name, {:ok, out}), do: "  #{name}\n      #{out}"
  defp reduce(name, {:error, msg}), do: "  #{name}\n      raised: #{msg}"
end
