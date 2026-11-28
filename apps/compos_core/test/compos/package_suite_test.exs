defmodule Compos.PackageSuiteTest do
  @moduledoc """
  Runs the Scheme tests that live beside the packages, as in Emacs:
  scheme/packages/NAME-test.scm, or NAME-test.scm inside a package's own
  directory. The kernel's run does not include them. Run them apart:

      mix test --include packages test/compos/package_suite_test.exs
      SCHEME_TESTS=morg mix test --include packages test/compos/package_suite_test.exs

  A community package keeps its tests in its own repo. Name it in
  SCHEME_TESTS and the run loads it from its clone in COMPOS_PACKAGE_REPOS
  (default ~/.compos-dev/repos) first:

      SCHEME_TESTS=org mix test --include packages test/compos/package_suite_test.exs
  """

  use ExUnit.Case

  alias Compos.SchemeSuite

  @moduletag :packages

  # Repo-only by default: local clones under COMPOS_PACKAGE_REPOS never enter
  # load-path unless SCHEME_TESTS names them, so machine checkouts cannot
  # shadow bundled packages or change the suite.
  setup_all do
    wanted =
      (System.get_env("SCHEME_TESTS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    if wanted != [] do
      repos = System.get_env("COMPOS_PACKAGE_REPOS") || Path.expand("~/.compos-dev/repos")

      named =
        for name <- wanted,
            dir = Path.join(repos, name),
            File.exists?(Path.join(dir, name <> ".scm")),
            do: {name, dir}

      if named != [] do
        dirs = Enum.map_join(named, " ", fn {_, dir} -> inspect(dir) end)

        {:ok, _} =
          Compos.Core.Session.eval(
            ~s{(begin (set! load-path (append load-path (list #{dirs}))) #t)}
          )

        for {name, _} <- named do
          {:ok, _} = Compos.Core.Session.eval(~s{(begin (require '#{name}) #t)})
        end
      end
    end

    :ok
  end

  test "every package test file registered every test it declares" do
    missing = SchemeSuite.missing(:packages, SchemeSuite.names(:packages))
    assert missing == [], "declared but not registered:\n" <> Enum.join(missing, "\n")
  end

  @tag timeout: 600_000
  test "the package tests pass" do
    found = SchemeSuite.names(:packages)
    real = found |> SchemeSuite.own(:packages) |> SchemeSuite.selected(:packages)
    assert real != [], "no package test matched SCHEME_TESTS=#{System.get_env("SCHEME_TESTS")}"

    failures = SchemeSuite.run(real)
    assert failures == [], "\n" <> Enum.join(failures, "\n")
  end
end
