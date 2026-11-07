defmodule Compos.TestHelpers do
  @moduledoc """
  The helpers every test used to copy: an eval that fails loudly, key
  presses through the same dispatch the GUI uses, and a poll.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Compos.Core.{Editor, KeyDispatch, Session}

  @doc "Evaluate Scheme in the session and return the printed value; a failure is the test's."
  def eval!(code, frame \\ nil, timeout \\ 30_000, lane \\ nil) do
    {:ok, printed} = Session.eval(code, frame, timeout, lane)
    printed
  end

  @doc "The frame shows its active window alone, through Scheme's test-one-window!: the reset a window test starts from."
  def one_window!(frame \\ nil), do: eval!("(test-one-window!)", frame)

  @doc """
  The frame's windows as (window-rects) answers: {BUFFER, [X, Y, W, H]} per
  window, in frame order. Each fraction is rounded to a thousandth, so a
  third compares as 0.333.
  """
  def window_layout(frame \\ nil) do
    for [_id, buffer, x, y, w, h] <- Editor.window_rects(frame),
        do: {buffer, Enum.map([x, y, w, h], &Float.round(&1 / 1, 3))}
  end

  @doc "The rectangles of the frame's windows alone, in frame order."
  def rects(frame \\ nil), do: for({_, rect} <- window_layout(frame), do: rect)

  @doc "The buffers the frame's windows show, in frame order, as (window-list) answers."
  def window_buffers(frame \\ nil), do: for({_, buffer} <- Editor.list_windows(frame), do: buffer)

  @doc "The first window that shows BUFFER, as (window-showing BUFFER) answers, or nil."
  def window_showing(buffer, frame \\ nil),
    do: Enum.find_value(Editor.list_windows(frame), fn {id, b} -> b == buffer && id end)

  @doc """
  What the client draws for window WIN, the active window by default, or
  nil when WIN is nil: the viewport (top, rows, total_lines), the cursor
  and the mode flags. The layout is not in it; read that with window_layout.
  """
  def rendered_window(win \\ :active, frame \\ nil) do
    win = if win == :active, do: Editor.active_window(frame), else: win
    win && find_window(Editor.render_state(frame).tree, win)
  end

  defp find_window(%{type: :leaf, id: id} = leaf, id), do: leaf
  defp find_window(%{type: :leaf}, _id), do: nil
  defp find_window(%{type: :split, children: c}, id), do: Enum.find_value(c, &find_window(&1, id))

  @doc "The agent slug of chat buffer BUF: the chat's stable id (chat-...), not the aN of its name."
  def slug_of(buf), do: Compos.Core.Buffer.get_local(buf, "agent-slug")

  @doc "Evaluate an (execute* ...) form; answer the new chat's {slug, buffer}. A buffer name is not stable across tests."
  def spawn_chat!(code) do
    slug = code |> eval!() |> String.trim("\"")
    {slug, Compos.Core.Agent.info(slug).buffer}
  end

  @doc "Press one key or a list of keys through KeyDispatch, the path the GUI takes."
  def press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  @doc "Press the keys on FRAME."
  def press(frame, keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key(frame, &1))

  @doc "Type a string, one self-inserting key per grapheme."
  def type(text), do: text |> String.graphemes() |> press()

  @doc "Poll FUN every 20ms until it answers true; flunk after TRIES."
  def wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end
end

defmodule Compos.Case do
  @moduledoc """
  `use Compos.Case` in place of `use ExUnit.Case`: the same case, with
  eval!, press, type and wait_until imported.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Compos.TestHelpers
    end
  end
end
