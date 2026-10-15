defmodule Compos.Core.Reactor do
  @moduledoc """
  The reactive rule engine: `on_change(buffer, matcher, handler, opts)`.

  This is the orchestrator's trigger primitive — "when X appears in buffer Y,
  run Z" — with debouncing and provenance filtering (loop prevention: rules
  ignore agent-sourced edits unless they opt in via `sources: :all`).

  Matchers today: `{:contains, string}` | fun(change -> bool) | `:any`.
  TODO: `{:ts_query, query, lang}` once the tree-sitter NIF lands — match
  against changed ranges of the incremental parse, not raw text.

  Handlers run in supervised Tasks: a crashing handler never takes down the
  reactor or the buffer.

  ## Visibility

  Background work follows the screen, widened by the current group —
  groups are the editor's organising principle. A rule fires while its
  buffer is visible in some window, or while it shares a 'group with the
  CURRENT buffer (each frame's active window): the working set the reader
  is in stays coherent as a whole. On any other buffer the changes
  accumulate as a parked redo; the rule fires once when the buffer comes
  back into scope. A daemon restart drops the parked redo, and the mode
  setup fn re-derives the same state from the restored text — a restart
  IS the redo. A rule that must run off-screen (its output leaves the
  buffer) opts out with `eager: true`.
  """

  use GenServer

  require Logger

  alias Compos.Core.{Buffer, Editor, Events}

  defstruct rules: %{}, by_buffer: %{}, next_id: 1

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Register a rule. Returns rule id.

  Options: `debounce: ms` (default 0), `sources: [:user] | :all` (default
  [:user]), `eager: true` (default false — fire only while the buffer is
  visible).
  Handler receives the list of accumulated changes (oldest first).
  """
  def on_change(buffer, matcher, handler, opts \\ []) do
    GenServer.call(__MODULE__, {:on_change, buffer, matcher, handler, opts})
  end

  def remove(rule_id), do: GenServer.call(__MODULE__, {:remove, rule_id})
  def rules, do: GenServer.call(__MODULE__, :rules)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Events.subscribe_editor()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:on_change, buffer, matcher, handler, opts}, _from, state) do
    buffer_ref = Buffer.ref(buffer)
    id = state.next_id

    unless Map.has_key?(state.by_buffer, buffer_ref) do
      Events.subscribe(buffer_ref)
    end

    rule = %{
      id: id,
      buffer_ref: buffer_ref,
      matcher: matcher,
      handler: handler,
      debounce: Keyword.get(opts, :debounce, 0),
      sources: Keyword.get(opts, :sources, [:user]),
      eager: Keyword.get(opts, :eager, false),
      pending: [],
      timer: nil,
      in_flight: false,
      failures: 0
    }

    state = %{
      state
      | rules: Map.put(state.rules, id, rule),
        by_buffer: Map.update(state.by_buffer, buffer_ref, MapSet.new([id]), &MapSet.put(&1, id)),
        next_id: id + 1
    }

    {:reply, {:ok, id}, state}
  end

  def handle_call({:remove, id}, _from, state) do
    case state.rules[id] do
      nil ->
        {:reply, :ok, state}

      rule ->
        {:reply, :ok, drop_rule(state, id, rule)}
    end
  end

  def handle_call(:rules, _from, state), do: {:reply, Map.values(state.rules), state}

  # A failed batch goes back on the queue, because the usual failure is
  # transient: a hot reload purges the module a handler came from, the retry
  # runs the new one. The retry itself is what needed a bound. A handler that
  # cannot finish this text will not finish it on the tenth attempt either,
  # and it retries with the batch still growing. On 2026-09-09 a rule over a
  # 3.8 MB chat buffer passed the 1024 MB Scheme heap limit every twelve
  # seconds. It held the :ui lane, so every desktop save timed out, and no
  # Scheme registry still held its id, so nothing in the editor could remove
  # it.
  #
  # Three failures in a row and the rule goes. The log names the buffer,
  # because that is the only thread left to pull.
  @max_failures 3

  # Map.get, not rule.failures: a hot reload swaps this module while the
  # running Reactor still holds rules that were built before the key existed,
  # and a KeyError here would take every rule in the editor down with it.
  defp note_failure(state, id, rule, changes, error) do
    case buffer_name(rule.buffer_ref) do
      # the buffer died while the handler ran (a kill mid-paint): any call
      # into it exits :noproc. That is the rule's end, not a failure.
      nil -> drop_rule(state, id, rule)
      name -> note_failure(state, id, rule, changes, error, name)
    end
  end

  defp note_failure(state, id, rule, changes, error, name) do
    failures = Map.get(rule, :failures, 0) + 1

    rule =
      rule
      |> Map.put(:pending, rule.pending ++ Enum.reverse(changes))
      |> Map.put(:timer, nil)
      |> Map.put(:failures, failures)

    if failures >= @max_failures do
      Logger.error(
        "reactor rule #{id} on #{name} removed after #{failures} failures: #{error}. " <>
          "Its mode must register a new rule to run again."
      )

      drop_rule(state, id, rule)
    else
      Logger.error("reactor rule #{id} on #{name} failed (#{failures}/#{@max_failures}): #{error}")

      put_in(state.rules[id], rule)
    end
  end

  defp drop_rule(state, id, rule) do
    if rule.timer, do: Process.cancel_timer(rule.timer)
    if rule.in_flight, do: Process.demonitor(rule.in_flight.monitor, [:flush])

    ids = state.by_buffer |> Map.get(rule.buffer_ref, MapSet.new()) |> MapSet.delete(id)

    by_buffer =
      if MapSet.size(ids) == 0 do
        Events.unsubscribe(rule.buffer_ref)
        Map.delete(state.by_buffer, rule.buffer_ref)
      else
        Map.put(state.by_buffer, rule.buffer_ref, ids)
      end

    %{state | rules: Map.delete(state.rules, id), by_buffer: by_buffer}
  end

  @impl true
  def handle_info({:buffer_change, buffer, change}, state) do
    rules =
      state.by_buffer
      |> Map.get(buffer, MapSet.new())
      |> Enum.reduce(state.rules, fn id, rules ->
        Map.update!(rules, id, &maybe_accumulate(&1, change))
      end)

    {:noreply, %{state | rules: rules}}
  end

  def handle_info({:fire, id}, state) do
    case state.rules[id] do
      nil ->
        {:noreply, state}

      %{pending: []} ->
        {:noreply, state}

      %{in_flight: in_flight} = rule when in_flight != false ->
        {:noreply, put_in(state.rules[id], %{rule | timer: nil})}

      rule ->
        cond do
          # the buffer died with a change still pending (a kill inside the
          # debounce): its rule ends here. Reading its name would exit, and
          # that exit took the Reactor down with every rule in the editor.
          buffer_name(rule.buffer_ref) == nil ->
            {:noreply, drop_rule(state, id, rule)}

          rule.eager or in_scope?(rule.buffer_ref, screen()) ->
            fire_rule(state, id, rule)

          true ->
            # park: keep the redo, drop the timer. The :changed subscription
            # below re-arms it when the buffer reaches a window.
            {:noreply, put_in(state.rules[id], %{rule | timer: nil})}
        end
    end
  end

  defp fire_rule(state, id, rule) do
    changes = Enum.reverse(rule.pending)
    handler = rule.handler
    reactor = self()

    case Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
           result = run_handler(handler, changes)
           send(reactor, {:handler_done, id, changes, result})
         end) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        in_flight = %{monitor: monitor, changes: changes}
        rule = %{rule | pending: [], timer: nil, in_flight: in_flight}
        {:noreply, put_in(state.rules[id], rule)}

      {:error, reason} ->
        Logger.error("reactor rule #{id} could not start: #{inspect(reason)}")
        {:noreply, put_in(state.rules[id], %{rule | timer: nil})}
    end
  end

  def handle_info({:handler_done, id, changes, result}, state) do
    case state.rules[id] do
      nil ->
        {:noreply, state}

      rule ->
        Process.demonitor(rule.in_flight.monitor, [:flush])
        rule = %{rule | in_flight: false}

        if handler_ok?(result) do
          {:noreply, put_in(state.rules[id], arm_pending(Map.put(rule, :failures, 0)))}
        else
          {:noreply, note_failure(state, id, rule, changes, handler_error(result))}
        end
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.rules, fn {_id, rule} ->
           rule.in_flight != false and rule.in_flight.monitor == monitor
         end) do
      nil ->
        {:noreply, state}

      {id, rule} ->
        attempted = rule.in_flight.changes
        rule = %{rule | in_flight: false}
        {:noreply, note_failure(state, id, rule, attempted, "task exited: #{inspect(reason)}")}
    end
  end

  # the Editor firehose: any editor mutation may have put a parked buffer
  # on screen. Cheap when nothing is parked; one visibility read otherwise.
  def handle_info({:editor_change, _what}, state) do
    parked =
      Enum.filter(state.rules, fn {_id, r} ->
        r.pending != [] and r.timer == nil and r.in_flight == false
      end)

    case parked do
      [] ->
        {:noreply, state}

      parked ->
        screen = screen()

        rules =
          Enum.reduce(parked, state.rules, fn {id, rule}, rules ->
            if in_scope?(rule.buffer_ref, screen) do
              Map.put(rules, id, %{
                rule
                | timer: Process.send_after(self(), {:fire, id}, 0)
              })
            else
              rules
            end
          end)

        {:noreply, %{state | rules: rules}}
    end
  end

  defp maybe_accumulate(rule, change) do
    if source_ok?(rule, change) and matches?(rule.matcher, change) do
      rule = %{rule | pending: [change | rule.pending]}

      if rule.timer != nil or rule.in_flight != false do
        rule
      else
        arm_pending(rule)
      end
    else
      rule
    end
  end

  defp arm_pending(%{pending: []} = rule), do: rule

  defp arm_pending(rule) do
    %{rule | timer: Process.send_after(self(), {:fire, rule.id}, rule.debounce)}
  end

  # A handler is a fun or `{module, function, args}`; the MFA form gets the
  # changes appended. Use the MFA form for a rule that outlives a hot reload:
  # a fun belongs to one version of its module's code, and the next reload of
  # that module purges the version, so the fun raises on every fire after it.
  # An external call resolves to the current version every time.
  defp run_handler({m, f, args}, changes) when is_atom(m) and is_atom(f) and is_list(args) do
    {:ok, apply(m, f, args ++ [changes])}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp run_handler(handler, changes) do
    {:ok, handler.(changes)}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp handler_ok?({:ok, {:error, _}}), do: false
  defp handler_ok?({:ok, _}), do: true
  defp handler_ok?({:error, _}), do: false

  defp handler_error({:ok, {:error, message}}), do: to_string(message)
  defp handler_error({:error, message}), do: to_string(message)

  # :locals is the phantom change buffer-set-local! broadcasts so views
  # repaint. It is not an edit. A rule that hears it and writes a local in
  # response feeds itself forever — morg did, at one full core. :all means
  # every EDIT source; the phantom stays excluded, as buffer.ex promises.
  defp source_ok?(%{sources: :all}, %{source: :locals}), do: false
  defp source_ok?(%{sources: :all}, _change), do: true
  defp source_ok?(%{sources: allowed}, %{source: src}), do: src in allowed

  defp matches?(:any, _change), do: true
  defp matches?({:contains, str}, %{inserted: text}), do: String.contains?(text, str)
  defp matches?(fun, change) when is_function(fun, 1), do: fun.(change)

  # no Editor (a bare test) means nothing is on screen anywhere: fire —
  # gating exists to spare the screen-less work, not to create it
  defp screen do
    if Process.whereis(Editor), do: Editor.visible_buffers(), else: :all
  end

  # in scope: on screen, or in the same group as a current buffer
  defp in_scope?(_b, :all), do: true

  defp in_scope?(ref, %{visible: visible, current: current}) do
    case buffer_name(ref) do
      nil ->
        false

      name ->
        name in visible or
          case group_of(ref) do
            nil -> false
            g -> g in Enum.map(current, &group_of/1)
          end
    end
  end

  # a buffer's name, or nil when its process is gone
  defp buffer_name(ref) do
    Buffer.name(ref)
  catch
    :exit, _ -> nil
  end

  # the group tag is the 'group buffer-local; 'companion-of is the
  # pre-group pointer that doubles as a tag (same fallback as buffer-group)
  defp group_of(b) do
    Compos.Core.Buffer.get_local(b, "group") ||
      Compos.Core.Buffer.get_local(b, "companion-of")
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
