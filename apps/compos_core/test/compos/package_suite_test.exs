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

  # every clone goes on load-path, so a package finds the clones it
  # requires; each name of SCHEME_TESTS that has a clone then loads, and its
  # NAME-test.scm is found beside it
  setup_all do
    repos = System.get_env("COMPOS_PACKAGE_REPOS") || Path.expand("~/.compos-dev/repos")
    clones = for dir <- Path.wildcard(Path.join(repos, "*")), File.exists?(Path.join(dir, Path.basename(dir) <> ".scm")), do: dir

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(begin (set! load-path (append load-path (list #{Enum.map_join(clones, " ", &inspect/1)}))) #t)}
      )

    for name <- String.split(System.get_env("SCHEME_TESTS") || "", ",", trim: true),
        Path.join(repos, name) in clones do
      {:ok, _} = Compos.Core.Session.eval(~s{(begin (require '#{name}) #t)})
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
