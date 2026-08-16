defmodule Aimax.Ui.Oembed do
  @moduledoc """
  Cache of tweet cards for the markdown preview.

  `card/1` answers from the ETS table at once. On a miss it starts one
  fetch, returns `:pending`, and the caller renders a placeholder. When
  the fetch ends, the server stores the result, bumps the generation
  counter, and pings the callers. The preview cache key contains the
  generation, so the next render picks up the card.

  The fetch asks the oEmbed endpoint for `omit_script`: the card is a
  plain blockquote. The preview iframe runs no scripts, so a static
  card is the only kind that can render there.
  """

  use GenServer

  @table :aimax_oembed
  @endpoint "https://publish.twitter.com/oembed"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Returns {:ok, html} | :error | :pending for a tweet URL."
  def card(url) do
    case :ets.lookup(@table, url) do
      [{^url, result}] ->
        result

      [] ->
        # the test env sets oembed_fetch false: a miss stays pending and
        # no request leaves the VM
        if Application.get_env(:aimax_ui, :oembed_fetch, true) do
          GenServer.cast(__MODULE__, {:fetch, url, self()})
        end

        :pending
    end
  end

  @doc "A counter that moves when any fetch completes; cache keys include it."
  def generation do
    case :ets.lookup(@table, :gen) do
      [{:gen, n}] -> n
      [] -> 0
    end
  end

  @doc false
  def put(url, result) do
    :ets.insert(@table, {url, result})
    :ets.update_counter(@table, :gen, 1, {:gen, 0})
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{inflight: %{}}}
  end

  @impl true
  def handle_cast({:fetch, url, from}, state) do
    case state.inflight do
      %{^url => waiters} ->
        {:noreply, put_in(state.inflight[url], [from | waiters])}

      _ ->
        server = self()
        Task.start(fn -> send(server, {:done, url, fetch(url)}) end)
        {:noreply, put_in(state.inflight[url], [from])}
    end
  end

  @impl true
  def handle_info({:done, url, result}, state) do
    {waiters, inflight} = Map.pop(state.inflight, url, [])
    put(url, result)
    # the same message a buffer edit sends: the LiveView re-renders and
    # the new generation misses the preview cache
    for pid <- waiters, do: send(pid, {:editor_change, :oembed})
    {:noreply, %{state | inflight: inflight}}
  end

  defp fetch(url) do
    Req.get(@endpoint,
      params: [url: url, omit_script: true, dnt: true],
      receive_timeout: 10_000
    )
    |> case do
      {:ok, %{status: 200, body: %{"html" => html}}} when is_binary(html) ->
        {:ok, strip_scripts(html)}

      _ ->
        :error
    end
  end

  # omit_script asks for no script tag; strip any anyway — the card must
  # carry no script into the preview document
  defp strip_scripts(html),
    do: Regex.replace(~r{<script\b[^>]*>.*?</script>|<script\b[^>]*/?>}is, html, "")
end
