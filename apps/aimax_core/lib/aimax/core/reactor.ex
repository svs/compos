defmodule Aimax.Core.Reactor do
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
  """

  use GenServer

  alias Aimax.Core.Events

  defstruct rules: %{}, next_id: 1

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Register a rule. Returns rule id.

  Options: `debounce: ms` (default 0), `sources: [:user] | :all` (default [:user]).
  Handler receives the list of accumulated changes (oldest first).
  """
  def on_change(buffer, matcher, handler, opts \\ []) do
    GenServer.call(__MODULE__, {:on_change, buffer, matcher, handler, opts})
  end

  def remove(rule_id), do: GenServer.call(__MODULE__, {:remove, rule_id})
  def rules, do: GenServer.call(__MODULE__, :rules)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:on_change, buffer, matcher, handler, opts}, _from, state) do
    Events.subscribe(buffer)

    rule = %{
      id: state.next_id,
      buffer: buffer,
      matcher: matcher,
      handler: handler,
      debounce: Keyword.get(opts, :debounce, 0),
      sources: Keyword.get(opts, :sources, [:user]),
      pending: [],
      timer: nil
    }

    state = %{state | rules: Map.put(state.rules, rule.id, rule), next_id: rule.id + 1}
    {:reply, {:ok, rule.id}, state}
  end

  def handle_call({:remove, id}, _from, state),
    do: {:reply, :ok, %{state | rules: Map.delete(state.rules, id)}}

  def handle_call(:rules, _from, state), do: {:reply, Map.values(state.rules), state}

  @impl true
  def handle_info({:buffer_change, buffer, change}, state) do
    rules =
      Map.new(state.rules, fn {id, rule} ->
        {id, maybe_accumulate(rule, buffer, change)}
      end)

    {:noreply, %{state | rules: rules}}
  end

  def handle_info({:fire, id}, state) do
    case state.rules[id] do
      nil ->
        {:noreply, state}

      %{pending: []} ->
        {:noreply, state}

      rule ->
        changes = Enum.reverse(rule.pending)
        handler = rule.handler
        Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn -> handler.(changes) end)
        {:noreply, put_in(state.rules[id], %{rule | pending: [], timer: nil})}
    end
  end

  defp maybe_accumulate(rule, buffer, change) do
    if rule.buffer == buffer and source_ok?(rule, change) and matches?(rule.matcher, change) do
      rule = %{rule | pending: [change | rule.pending]}

      if rule.timer do
        rule
      else
        %{rule | timer: Process.send_after(self(), {:fire, rule.id}, rule.debounce)}
      end
    else
      rule
    end
  end

  defp source_ok?(%{sources: :all}, _change), do: true
  defp source_ok?(%{sources: allowed}, %{source: src}), do: src in allowed

  defp matches?(:any, _change), do: true
  defp matches?({:contains, str}, %{inserted: text}), do: String.contains?(text, str)
  defp matches?(fun, change) when is_function(fun, 1), do: fun.(change)
end
