defmodule Aimax.ImenuTest do
  @moduledoc """
  imenu on the outline contract: the index is (code-outline BUF) — or the
  morg headings — never a per-language query table.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Session}

  @buf "imenu-test.py"

  defp eval!(code) do
    {:ok, v} = Session.eval(code)
    v
  end

  setup do
    eval!("""
    (begin
      (buffer-create "#{@buf}")
      (switch-to-buffer! "#{@buf}")
      (buffer-insert! "#{@buf}" 0 "def alpha():\\n    return 1\\n\\ndef beta():\\n    return 2\\n"))
    """)

    on_exit(fn ->
      if Buffer.exists?(@buf), do: Aimax.Core.kill_buffer(@buf)
    end)

    :ok
  end

  test "the index is the outline: every buffer answers" do
    rows = eval!(~s[(imenu-rows "#{@buf}")])
    assert rows =~ "alpha"
    assert rows =~ "beta"
    assert rows =~ ~s{"block"}
  end

  test "candidates carry kind and line; a repeated name stays reachable" do
    cands =
      eval!("""
      (imenu--candidates
        (quote ((1 "block" "bar" "def bar") (5 "block" "bar" "def bar")
                (9 "block" "baz" ""))))
      """)

    assert cands =~ ~s{"bar (L5)"}
    assert cands =~ "block · L1"
    refute cands =~ ~s{"baz (L}
  end

  test "a morg buffer indexes its headings" do
    eval!("""
    (begin
      (buffer-set-local! "#{@buf}" 'mode-name "morg-mode")
      (buffer-delete-range! "#{@buf}" 0 (buffer-size "#{@buf}"))
      (buffer-insert! "#{@buf}" 0 "# One\\nbody\\n## Two\\n"))
    """)

    rows = eval!(~s[(imenu-rows "#{@buf}")])
    assert rows =~ "# One"
    assert rows =~ "## Two"
    refute rows =~ "body"
  end

  test "an empty buffer reports instead of prompting" do
    eval!(~s[(buffer-delete-range! "#{@buf}" 0 (buffer-size "#{@buf}"))])
    assert {:ok, _} = Session.eval(~s[(run-command "imenu")])
  end
end
