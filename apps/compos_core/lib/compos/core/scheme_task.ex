defmodule Compos.Core.SchemeTask do
  @moduledoc """
  A supervised, one-shot Scheme computation over the live shared world.

  Each task is a BEAM process with its own evaluator stack and local frames.
  Global Scheme bindings and editor services are shared; buffers retain their
  normal per-buffer serialization. This makes task fan-out cheap: it does not
  copy the booted Scheme environment.
  """

  use GenServer

  alias Compos.Core.{Frame, SchemeReadLimiter, Session}
  alias Compos.Scheme

  @registry Compos.Core.SchemeTaskRegistry
  @supervisor Compos.Core.SchemeTaskSupervisor
  @escaped :compos_escaped_closures
  @retire_after 300_000

  defmodule Ref do
    @moduledoc "An opaque reference to a one-shot Scheme task."
    @enforce_keys [:id]
    defstruct [:id]
  end

  def start(closure, args \\ [], opts \\ []) when is_list(args) and is_list(opts) do
    id = :erlang.unique_integer([:positive, :monotonic])
    ref = %Ref{id: id}
    root = {:scheme_task, id}
    :ets.insert(@escaped, {root, closure})

    spec = %{
      id: {__MODULE__, id},
      start:
        {__MODULE__, :start_link,
         [
           {ref, closure, args, Session.interp(), Keyword.get(opts, :fid, Frame.current()),
            Keyword.get(opts, :buffer, Frame.buffer_context()), root, Keyword.get(opts, :owner),
            Keyword.get(opts, :label, "Scheme task")}
         ]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, _pid} ->
        {:ok, ref}

      {:error, reason} ->
        :ets.delete(@escaped, root)
        {:error, inspect(reason)}
    end
  end

  @doc "Run a Scheme closure synchronously in a supervised shared-world process."
  def call(closure, args, timeout \\ 30_000, opts \\ []) do
    opts = Keyword.put(opts, :owner, self())

    case start(closure, args, opts) do
      {:ok, ref} ->
        try do
          await(ref, timeout)
        after
          cancel(ref)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_link(args) do
    {ref, _closure, _args, _interp, _fid, _buffer, _root, _owner, _label} = args

    GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, ref.id}})
  end

  def await(%Ref{} = ref, timeout \\ 30_000) do
    case whereis(ref) do
      nil -> {:error, "task is not alive"}
      pid -> GenServer.call(pid, :await, timeout)
    end
  catch
    :exit, {:timeout, _} -> {:error, "task await timed out after #{timeout}ms"}
    :exit, reason -> {:error, "task await failed: #{inspect(reason)}"}
  end

  def cancel(%Ref{} = ref) do
    case whereis(ref) do
      nil ->
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(@supervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def alive?(%Ref{} = ref), do: is_pid(whereis(ref))
  def task_ref?(%Ref{}), do: true
  def task_ref?(_), do: false

  @impl true
  def init({ref, closure, args, interp, fid, buffer, root, owner, label}) do
    owner_monitor = if is_pid(owner), do: Process.monitor(owner), else: nil

    {:ok,
     %{
       ref: ref,
       closure: closure,
       args: args,
       interp: interp,
       fid: fid,
       buffer: buffer,
       root: root,
       owner_monitor: owner_monitor,
       label: label,
       result: nil
     }, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    started_at = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:compos, :scheme, :task, :start],
      %{system_time: System.system_time(:millisecond)},
      %{task: state.ref.id, label: state.label}
    )

    result = SchemeReadLimiter.run(fn -> run(state) end)
    duration = System.monotonic_time(:millisecond) - started_at
    status = if match?({:ok, _}, result), do: :ok, else: :error

    :telemetry.execute(
      [:compos, :scheme, :task],
      %{duration: duration},
      %{task: state.ref.id, status: status, label: state.label}
    )

    :ets.insert(@escaped, {state.root, result})
    Process.send_after(self(), :retire, @retire_after)
    {:noreply, %{state | closure: nil, args: nil, interp: nil, result: result}}
  end

  @impl true
  def handle_call(:await, _from, %{result: result} = state), do: {:reply, result, state}

  @impl true
  def handle_info(:retire, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state),
    do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state) do
    :ets.delete(@escaped, state.root)
    :ok
  end

  defp run(state) do
    fun = fn ->
      Scheme.exec(state.interp, fn interp -> Scheme.call(interp, state.closure, state.args) end)
    end

    result =
      Frame.with_frame(state.fid, fn ->
        if state.buffer, do: Frame.with_buffer(state.buffer, fun), else: fun.()
      end)

    case result do
      {:ok, value, _interp} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, "exit: #{inspect(reason)}"}
  end

  defp whereis(%Ref{id: id}) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
