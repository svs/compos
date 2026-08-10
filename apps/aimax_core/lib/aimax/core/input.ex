defmodule Aimax.Core.Input do
  @moduledoc """
  The input queue. A keystroke is a multi-call sequence (snapshot →
  lookup_key → set_pending → run_command); run from each LiveView's own
  process, two clients' sequences interleave mid-dispatch. Serializing whole
  input events here makes each one atomic with respect to the others.

  Each event carries its frame: dispatch stamps the frame context into this
  process and bumps the frame MRU, so everything downstream — KeyDispatch,
  Session, Scheme primitives — acts on the frame the keystroke came from.

  Runs in its own process — never inside Editor or Session — so command
  execution can freely call both (the KeyDispatch rule). Nothing downstream
  calls back into Input.
  """

  use GenServer

  alias Aimax.Core.{Editor, Frame, KeyDispatch}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Route one key event through KeyDispatch, serialized."
  def dispatch(key) when is_binary(key), do: dispatch(nil, key)

  def dispatch(fid, key),
    do: GenServer.call(__MODULE__, {:input, fid, fn -> KeyDispatch.handle_key(key) end}, :infinity)

  @doc "Run any input-event block (mouse, paste, modeline click), serialized."
  def run(fun) when is_function(fun, 0), do: run(nil, fun)

  def run(fid, fun) when is_function(fun, 0),
    do: GenServer.call(__MODULE__, {:input, fid, fun}, :infinity)

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:input, fid, fun}, _from, state) do
    if fid do
      Frame.put(fid)
      Editor.touch_frame(fid)
    else
      Frame.clear()
    end

    {:reply, fun.(), state}
  end
end
