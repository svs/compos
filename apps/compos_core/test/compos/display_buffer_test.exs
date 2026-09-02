defmodule Compos.DisplayBufferTest do
  @moduledoc "The Scheme display-buffer tests, in this daemon: they rearrange windows, so never in the live one."
  use ExUnit.Case

  alias Compos.Core.{Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    :ok
  end

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "display-buffer-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp names do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_))
    |> Enum.map(fn [_, name] -> name end)
  end

  @tag timeout: 120_000
  test "display-buffer-test.scm passes" do
    {:ok, _} = Session.eval(~s{(load "#{@file_}")}, nil, 30_000, @lane)
    names = names()
    assert names != [], "the file declares no test"

    for name <- names do
      case Session.eval("(run-test '#{name})", nil, 60_000, @lane) do
        {:ok, "()"} -> :ok
        {:ok, failures} -> flunk("#{name} failed: #{failures}")
        {:error, err} -> flunk("#{name} raised: #{err}")
      end
    end
  end
end
