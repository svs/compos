defmodule Aimax.Core.SchemeActor do
  @moduledoc """
  An isolated Scheme process with a private environment and a serial mailbox.

  A behavior receives `(STATE MESSAGE)` and returns `(NEW-STATE REPLY)`.
  Cast delivery ignores the reply. Call delivery returns it to the sender.
  Messages, initial state, and replies must not contain Scheme closures.
  """

  use GenServer

  require Logger

  alias Aimax.Scheme
  alias Aimax.Scheme.{Env, Eval}

  @registry Aimax.Core.SchemeActorRegistry
  @supervisor Aimax.Core.SchemeActorSupervisor
  @gc_check_interval 100
  @gc_growth_floor 1_000

  defmodule Ref do
    @moduledoc "An opaque reference to an isolated Scheme actor."
    @enforce_keys [:id]
    defstruct [:id]
  end

  def start(%Scheme{} = interp, behavior, initial_state) do
    with :ok <- data_only(initial_state, "initial state") do
      id = :erlang.unique_integer([:positive, :monotonic])
      ref = %Ref{id: id}
      snapshot = Scheme.snapshot(interp)

      spec = %{
        id: {__MODULE__, id},
        start: {__MODULE__, :start_link, [{ref, snapshot, behavior, initial_state}]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(@supervisor, spec) do
        {:ok, _pid} -> {:ok, ref}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  def start_link({%Ref{} = ref, snapshot, behavior, initial_state}) do
    GenServer.start_link(__MODULE__, {ref, snapshot, behavior, initial_state},
      name: {:via, Registry, {@registry, ref.id}}
    )
  end

  def cast(%Ref{} = ref, message) do
    with :ok <- data_only(message, "message"),
         pid when is_pid(pid) <- whereis(ref) do
      GenServer.cast(pid, {:deliver, message})
      :ok
    else
      nil -> {:error, "actor is not alive"}
      {:error, _} = error -> error
    end
  end

  def call(%Ref{} = ref, message, timeout \\ 5_000) do
    with :ok <- data_only(message, "message"),
         pid when is_pid(pid) <- whereis(ref),
         false <- pid == self() do
      GenServer.call(pid, {:call, message}, timeout)
    else
      nil -> {:error, "actor is not alive"}
      true -> {:error, "an actor cannot call itself"}
      {:error, _} = error -> error
    end
  catch
    :exit, reason -> {:error, "actor call failed: #{inspect(reason)}"}
  end

  def deliver_after(%Ref{} = ref, milliseconds, message)
      when is_integer(milliseconds) and milliseconds >= 0 do
    with :ok <- data_only(message, "message"),
         pid when is_pid(pid) <- whereis(ref) do
      Process.send_after(pid, {:deliver, message}, milliseconds)
      :ok
    else
      nil -> {:error, "actor is not alive"}
      {:error, _} = error -> error
    end
  end

  def monitor(%Ref{} = observer, %Ref{} = target, tag) do
    with :ok <- data_only(tag, "monitor tag"),
         observer_pid when is_pid(observer_pid) <- whereis(observer),
         target_pid when is_pid(target_pid) <- whereis(target) do
      GenServer.call(observer_pid, {:monitor, target_pid, tag})
    else
      nil -> {:error, "actor is not alive"}
      {:error, _} = error -> error
    end
  catch
    :exit, reason -> {:error, "could not monitor actor: #{inspect(reason)}"}
  end

  def stop(%Ref{} = ref) do
    case whereis(ref) do
      nil ->
        :ok

      pid when pid == self() ->
        send(pid, :stop)
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(@supervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def alive?(%Ref{} = ref) do
    case whereis(ref) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end

  def actor_ref?(%Ref{}), do: true
  def actor_ref?(_), do: false
  def current, do: Process.get(:aimax_scheme_actor) || false

  defp whereis(%Ref{id: id}) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init({ref, snapshot, behavior, initial_state}) do
    Process.put(:aimax_scheme_actor, ref)
    Process.put(:aimax_scheme_host_guard, &guard_host_primitive/2)

    {:ok,
     %{
       ref: ref,
       interp: Scheme.from_snapshot(snapshot),
       behavior: behavior,
       value: initial_state,
       monitors: %{},
       processed: 0,
       last_live: nil
     }}
  end

  @impl true
  def handle_cast({:deliver, message}, state) do
    case apply_behavior(state, message) do
      {:ok, next, _reply, interp} ->
        {:noreply, advance(state, next, interp)}

      {:error, reason} ->
        Logger.error("Scheme actor #{state.ref.id} rejected a message: #{reason}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:monitor, target_pid, tag}, _from, state) do
    monitor = Process.monitor(target_pid)
    {:reply, :ok, %{state | monitors: Map.put(state.monitors, monitor, tag)}}
  end

  def handle_call({:call, message}, _from, state) do
    case apply_behavior(state, message) do
      {:ok, next, reply, interp} ->
        {:reply, {:ok, reply}, advance(state, next, interp)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:deliver, message}, state), do: handle_cast({:deliver, message}, state)

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {tag, monitors} ->
        message = [{:sym, "down"}, tag, inspect(reason)]
        handle_cast({:deliver, message}, %{state | monitors: monitors})
    end
  end

  def handle_info(:stop, state), do: {:stop, :normal, state}

  defp advance(state, value, interp) do
    processed = state.processed + 1
    state = %{state | value: value, interp: interp, processed: processed}

    if rem(processed, @gc_check_interval) == 0 do
      collect_if_needed(state)
    else
      state
    end
  end

  defp collect_if_needed(%{last_live: nil} = state) do
    %{state | last_live: Scheme.frame_count(state.interp)}
  end

  defp collect_if_needed(state) do
    count = Scheme.frame_count(state.interp)

    if count > state.last_live + @gc_growth_floor do
      interp = Scheme.gc(state.interp, [state.behavior, state.value])
      %{state | interp: interp, last_live: Scheme.frame_count(interp)}
    else
      state
    end
  end

  defp apply_behavior(state, message) do
    case Scheme.exec(state.interp, fn interp ->
           Scheme.call(interp, state.behavior, [state.value, message])
         end) do
      {:ok, [next, reply], interp} ->
        case data_only(reply, "reply") do
          :ok -> {:ok, next, reply, interp}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _other, _interp} ->
        {:error, "behavior must return (NEW-STATE REPLY)"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp data_only(value, label) do
    cond do
      Env.closure_refs(value, []) != [] ->
        {:error, "actor #{label} cannot contain a closure"}

      executable_value?(value) ->
        {:error, "actor #{label} cannot contain an executable value"}

      true ->
        :ok
    end
  end

  defp executable_value?({:builtin, _name, _fun}), do: true
  defp executable_value?(value) when is_function(value), do: true
  defp executable_value?(list) when is_list(list), do: Enum.any?(list, &executable_value?/1)

  defp executable_value?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&executable_value?/1)

  defp executable_value?(%_{} = struct),
    do: struct |> Map.from_struct() |> executable_value?()

  defp executable_value?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} -> executable_value?(key) or executable_value?(value) end)
  end

  defp executable_value?(_value), do: false

  defp guard_host_primitive("actor-spawn", _args), do: :ok

  defp guard_host_primitive(name, args) do
    if Env.closure_refs(args, []) != [] do
      raise Eval.Error,
        message: "isolated actor cannot export a closure through #{name}"
    end

    :ok
  end
end
