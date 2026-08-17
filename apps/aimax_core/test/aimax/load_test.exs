defmodule Aimax.LoadTest do
  @moduledoc """
  (load ...) is how init.scm sources more config. A relative path resolves
  against the config home, not the daemon's working directory.
  """

  use ExUnit.Case

  alias Aimax.Core.Session

  test "(load ...) resolves a relative path against the config home" do
    home = Aimax.Core.home()
    File.write!(Path.join(home, "load-relative-test.scm"), "(define load-relative-mark 42)\n")

    on_exit(fn -> File.rm(Path.join(home, "load-relative-test.scm")) end)

    # relative: found under the config home
    assert {:ok, _} = Session.eval(~s{(load "load-relative-test.scm")})
    assert {:ok, "42"} = Session.eval("load-relative-mark")

    # an absolute path still works
    abs = Path.join(home, "load-relative-test.scm")
    assert {:ok, _} = Session.eval(~s{(load "#{abs}")})
  end
end
