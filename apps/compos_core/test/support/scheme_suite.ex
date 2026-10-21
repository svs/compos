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

  @doc "Every test name the loaded suites registered."
  def names(kind) do
    eval!("(begin #{loader(kind)} (test-names))")
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(" ", trim: true)
  end

  @doc "The test files of KIND on disk."
  def files(:core), do: Path.wildcard(Path.join(core_dir(), "*.scm"))

  def files(:packages) do
    dir = package_dir()
    Path.wildcard(Path.join(dir, "*-test.scm")) ++ Path.wildcard(Path.join(dir, "*/*-test.scm"))
  end

  def core_dir, do: Path.join(:code.priv_dir(:compos_core), "tests")
  def package_dir, do: Path.join(Compos.Core.project_dir(), "scheme/packages")

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
    for path <- files(kind),
        name <- declared(path),
        name not in found,
        do: "#{Path.basename(path)}: #{name}"
  end

  @doc "Run NAMES one eval each; answers the failures, and prints times on SCHEME_TIMES."
  def run(names) do
    # the suite tests the editor's doors one at a time: the window model is
    # off while it runs, and the model's own tests turn it on themselves
    eval("(when (and (boundp 'panes-mode) panes-mode) (panes-mode-disable!))")

    {failures, times} =
      Enum.reduce(names, {[], []}, fn name, {fails, times} ->
        {us, result} = :timer.tc(fn -> eval("(run-test '#{name})") end)
        reduced = reduce(name, result)
        {if(reduced, do: [reduced | fails], else: fails), [{div(us, 1000), name} | times]}
      end)

    # SCHEME_TIMES=1 prints the slowest tests, for work on the editor's cost
    if System.get_env("SCHEME_TIMES") do
      times
      |> Enum.sort(:desc)
      |> Enum.take(25)
      |> Enum.each(fn {ms, name} -> IO.puts("  #{String.pad_leading(to_string(ms), 6)}ms  #{name}") end)
    end

    Enum.reverse(failures)
  end

  # "()" is a pass. Anything else is the test's own report, or the eval
  # died — which is a failure of that test and not of this one.
  defp reduce(_name, {:ok, "()"}), do: nil
  defp reduce(name, {:ok, out}), do: "  #{name}\n      #{out}"
  defp reduce(name, {:error, msg}), do: "  #{name}\n      raised: #{msg}"
end
