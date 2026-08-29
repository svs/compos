defmodule Compos.CodeBrowseTest do
  @moduledoc """
  code.scm: structural browsing, driven through KeyDispatch.handle_key/1 —
  the same path the GUI uses. Two backends answer the same six questions:
  tree-sitter for a buffer with a grammar, indentation for every other.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp fresh_buffer(text, lang) do
    name = "code-#{System.unique_integer([:positive])}"
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    if lang, do: Buffer.set_local(name, "ts-lang", lang)
    Buffer.goto(name, 0)
    name
  end

  defp browse!(buf) do
    eval!(~s{(enable-minor-mode! "#{buf}" "code-browse-mode")})
    buf
  end

  # the node the reader stands on, as {kind, start, stop}
  defp browse_node(buf) do
    [kind, s, e] = Buffer.get_local(buf, "code-node")
    {kind, s, e}
  end

  defp offset_of(text, needle), do: text |> :binary.match(needle) |> elem(0)

  defp offset_from(text, needle, from) do
    {pos, _} = :binary.match(text, needle, scope: {from, byte_size(text) - from})
    pos
  end

  defp scope_overlays(buf) do
    Enum.filter(Buffer.overlays(buf), fn {_, _, face} -> face == "code-scope" end)
  end

  @elixir """
  defmodule Fixture do
    def alpha(x) do
      x + 1
    end

    def beta(y) do
      y * 2
    end
  end
  """

  @outline """
  alpha
    one
    two
      deeper
  beta
    three
  """

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    on_exit(fn -> Editor.minibuffer_close() end)
    :ok
  end

  # --- tree-sitter backend ----------------------------------------------------

  test "entering browse mode stands on the definition around point" do
    buf = fresh_buffer(@elixir, "elixir")
    Buffer.goto(buf, offset_of(@elixir, "  def alpha"))
    browse!(buf)

    assert Buffer.get_local(buf, "code-backend") == "ts"
    {kind, start, _} = browse_node(buf)
    assert kind == "call"
    assert start == offset_of(@elixir, "def alpha")
    assert Buffer.point(buf) == start
    assert Buffer.read_only?(buf)
  end

  test "j and k walk the sibling definitions; h ascends to the module" do
    buf = fresh_buffer(@elixir, "elixir")
    Buffer.goto(buf, offset_of(@elixir, "  def alpha"))
    browse!(buf)

    press(["j"])
    assert Buffer.point(buf) == offset_of(@elixir, "def beta")

    press(["k"])
    assert Buffer.point(buf) == offset_of(@elixir, "def alpha")

    # up to the do block, then up to the defmodule itself
    press(["h"])
    press(["h"])
    assert Buffer.point(buf) == 0
    assert elem(browse_node(buf), 0) == "call"
  end

  test "l descends into the block inside a definition" do
    buf = fresh_buffer(@elixir, "elixir")
    Buffer.goto(buf, offset_of(@elixir, "  def alpha"))
    browse!(buf)

    press(["l"])
    {_, start, stop} = browse_node(buf)
    assert start > offset_of(@elixir, "def alpha")
    assert stop <= offset_of(@elixir, "def beta")
  end

  test "the scope overlay follows the node" do
    buf = fresh_buffer(@elixir, "elixir")
    Buffer.goto(buf, offset_of(@elixir, "  def alpha"))
    browse!(buf)

    {_, start, stop} = browse_node(buf)
    assert scope_overlays(buf) == [{start, stop, "code-scope"}]

    press(["j"])
    {_, s2, e2} = browse_node(buf)
    assert scope_overlays(buf) == [{s2, e2, "code-scope"}]
  end

  test "TAB folds the body of the node and folds it back" do
    buf = fresh_buffer(@elixir, "elixir")
    Buffer.goto(buf, offset_of(@elixir, "  def alpha"))
    browse!(buf)

    press(["TAB"])
    {_, start, stop} = browse_node(buf)
    first_line_end = offset_from(@elixir, "\n", start)
    assert Buffer.hidden(buf, "code") == [{first_line_end, stop}]

    press(["TAB"])
    assert Buffer.hidden(buf, "code") == []
  end

  test "TAB on a one-line node folds what holds it" do
    buf = fresh_buffer(@elixir, "elixir")
    # the body line of alpha: a node with no body of its own
    Buffer.goto(buf, offset_of(@elixir, "x + 1"))
    browse!(buf)
    Buffer.goto(buf, offset_of(@elixir, "x + 1"))

    press(["TAB"])
    [{s, e}] = Buffer.hidden(buf, "code")
    # it folded a block that holds the line, not nothing
    assert s < offset_of(@elixir, "x + 1")
    assert e >= offset_of(@elixir, "x + 1")
    # and point is outside the hidden range, on the head line
    assert Buffer.point(buf) <= s
  end

  test "RET leaves the mode: editable again, no tint, no folds" do
    buf = fresh_buffer(@elixir, "elixir")
    Buffer.goto(buf, offset_of(@elixir, "  def alpha"))
    browse!(buf)
    press(["TAB"])

    press(["RET"])
    refute Buffer.read_only?(buf)
    assert Buffer.hidden(buf, "code") == []
    assert scope_overlays(buf) == []
    assert Buffer.get_local(buf, "code-node") == false
    assert Buffer.get_local(buf, "minor-modes") == []

    # the keys are the buffer's own again
    press(["j"])
    assert Buffer.text(buf) =~ "j"
  end

  # --- indentation backend ----------------------------------------------------

  test "a buffer with no grammar browses by indentation" do
    buf = fresh_buffer(@outline, nil)
    Buffer.goto(buf, offset_of(@outline, "  one"))
    browse!(buf)

    assert Buffer.get_local(buf, "code-backend") == "indent"

    press(["j"])
    assert Buffer.point(buf) == offset_of(@outline, "  two")

    press(["h"])
    assert Buffer.point(buf) == offset_of(@outline, "alpha")

    press(["j"])
    assert Buffer.point(buf) == offset_of(@outline, "beta")
  end

  test "l descends one indentation level" do
    buf = fresh_buffer(@outline, nil)
    Buffer.goto(buf, 0)
    browse!(buf)

    press(["l"])
    assert Buffer.point(buf) == offset_of(@outline, "  one")

    # "deeper" sits under "two", so the descent goes through it
    press(["j", "l"])
    assert Buffer.point(buf) == offset_of(@outline, "deeper") - 4
  end

  # --- fold policy and restore -------------------------------------------------

  test "a long file folds its definitions on entry; a short one does not" do
    short = fresh_buffer(@elixir, "elixir")
    browse!(short)
    assert Buffer.hidden(short, "code") == []

    body = Enum.map_join(1..40, fn i -> "  def f#{i}(x) do\n    x + #{i}\n  end\n\n" end)
    long = fresh_buffer("defmodule Big do\n" <> body <> "end\n", "elixir")
    browse!(long)

    assert length(Buffer.hidden(long, "code")) == 40
  end

  test "restore-minor-modes! rebuilds the mode from the locals" do
    buf = fresh_buffer(@elixir, "elixir")
    Buffer.goto(buf, offset_of(@elixir, "  def alpha"))
    browse!(buf)
    press(["TAB"])
    before = browse_node(buf)
    folds = Buffer.hidden(buf, "code")

    # what a daemon restart leaves behind: the locals, nothing else
    Buffer.set_hidden(buf, "code", [])
    eval!(~s{(overlay-clear! "#{buf}" 'code-scope)})
    eval!(~s{(restore-minor-modes! "#{buf}")})

    assert browse_node(buf) == before
    assert Buffer.hidden(buf, "code") == folds
    assert scope_overlays(buf) != []
    assert Buffer.read_only?(buf)

    press(["RET"])
  end

  # --- eligibility ---------------------------------------------------------------

  test "a buffer with its own single keys keeps them" do
    # the shape of a diff buffer: no file path, its own n/TAB/RET
    name = "*fake-diff-#{System.unique_integer([:positive])}*"
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, "@@ -1,2 +1,2 @@\n-a\n+b\n", source: :editor)
    Buffer.set_local(name, "mode-name", "diff-mode")
    eval!(~s{(local-set-key* "#{name}" "n" "diff-next-hunk")})

    eval!(~s{(run-command "code-browse")})

    assert Buffer.get_local(name, "minor-modes") in [nil, false, []]
    assert {"n", "diff-next-hunk"} in Enum.map(Editor.local_keys(name), fn {k, c} -> {k, c} end)
    refute Buffer.read_only?(name)
  end

  test "a restored node that does not hold point gives way to point" do
    buf = fresh_buffer(@elixir, "elixir")
    Buffer.goto(buf, offset_of(@elixir, "  def alpha"))
    browse!(buf)
    # what a restart leaves: the old node in the local, point elsewhere
    Buffer.goto(buf, offset_of(@elixir, "def beta"))
    eval!(~s{(restore-minor-modes! "#{buf}")})

    {_, start, stop} = browse_node(buf)
    assert start <= offset_of(@elixir, "def beta")
    assert stop >= offset_of(@elixir, "def beta")
  end

  # --- go to definition --------------------------------------------------------

  test "M-. finds the definition of the symbol in this buffer" do
    buf = fresh_buffer(@elixir, "elixir")
    Buffer.goto(buf, offset_of(@elixir, "beta(y)"))
    browse!(buf)
    Buffer.goto(buf, offset_of(@elixir, "beta(y)"))

    press(["M-."])
    assert Buffer.point(buf) == offset_of(@elixir, "def beta")
  end
end
