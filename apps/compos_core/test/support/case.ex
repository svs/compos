defmodule Compos.TestHelpers do
  @moduledoc """
  The helpers every test used to copy: an eval that fails loudly, key
  presses through the same dispatch the GUI uses, and a poll.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Compos.Core.{KeyDispatch, Session}

  @doc "Evaluate Scheme in the session and return the printed value; a failure is the test's."
  def eval!(code, frame \\ nil, timeout \\ 30_000, lane \\ nil) do
    {:ok, printed} = Session.eval(code, frame, timeout, lane)
    printed
  end

  @doc "The frame shows its active window alone, through Scheme's test-one-window!: the reset a window test starts from."
  def one_window!(frame \\ nil), do: eval!("(test-one-window!)", frame)

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
