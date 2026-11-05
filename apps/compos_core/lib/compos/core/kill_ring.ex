defmodule Compos.Core.KillRing do
  @moduledoc """
  The kill ring: the killed texts, the newest first, 60 at most.

  Its own process, not a field of the Editor: a kill or a yank waits on
  nothing but this ring. Every write is one call here, so a kill-append
  from one lane and a kill from another never lose each other.
  """

  use GenServer

  @max 60

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, inherited()}

  # Started by hot reload into a running daemon, the ring takes the kills
  # the Editor held before it moved here. At boot the Editor is not up.
  defp inherited do
    case Process.whereis(Compos.Core.Editor) do
      nil -> []
      pid -> Map.get(:sys.get_state(pid, 1_000), :kill_ring, [])
    end
  catch
    :exit, _ -> []
  end

  @doc "Start the ring when a daemon loaded this module by hot reload."
  def ready do
    unless Process.whereis(__MODULE__),
      do: Supervisor.start_child(Compos.Core.Supervisor, __MODULE__)

    :ok
  end

  @doc "Put TEXT on the ring as its newest entry."
  def push(text), do: call({:push, text})

  @doc """
  Grow the newest entry with TEXT, in front when BEFORE?. Emacs
  kill-append: a kill that follows a kill grows the newest entry, so
  C-k C-k C-k yanks back as one piece.
  """
  def append(text, before?), do: call({:append, text, before?})

  @doc "The newest entry, or the empty string."
  def top, do: call({:nth, 0})

  @doc "The entry I back from the newest, or the empty string."
  def nth(i), do: call({:nth, i})

  def size, do: call(:size)

  defp call(msg) do
    ready()
    GenServer.call(__MODULE__, msg)
  end

  @impl true
  def handle_call({:push, text}, _from, ring), do: {:reply, :ok, Enum.take([text | ring], @max)}

  def handle_call({:append, text, before?}, _from, ring) do
    ring =
      case ring do
        [] -> [text]
        [top | rest] -> [if(before?, do: text <> top, else: top <> text) | rest]
      end

    {:reply, :ok, ring}
  end

  def handle_call({:nth, i}, _from, ring), do: {:reply, Enum.at(ring, i, ""), ring}
  def handle_call(:size, _from, ring), do: {:reply, length(ring), ring}
end
