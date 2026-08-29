defmodule Compos.Ui.Oembed do
  @moduledoc """
  Cache of tweet cards for the markdown preview.

  `card/1` answers from the ETS table at once. On a miss it starts one
  fetch, returns `:pending`, and the caller renders a placeholder. When
  the fetch ends, the server stores the result, bumps the generation
  counter, and pings the callers. The preview cache key contains the
  generation, so the next render picks up the card.

  The fetch reads the syndication CDN, which returns the tweet as JSON
  with author, text, and image URLs. `build_card/2` turns that into
  static HTML. The oEmbed blockquote is the fallback; it holds no
  images. The preview iframe runs no scripts, so a static card is the
  only kind that can render there.
  """

  use GenServer

  @table :compos_oembed
  @syndication "https://cdn.syndication.twimg.com/tweet-result"
  @oembed "https://publish.twitter.com/oembed"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Returns {:ok, html} | :error | :pending for a tweet URL."
  def card(url) do
    case :ets.lookup(@table, url) do
      [{^url, result}] ->
        result

      [] ->
        # the test env sets oembed_fetch false: a miss stays pending and
        # no request leaves the VM
        if Application.get_env(:compos_ui, :oembed_fetch, true) do
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
    with [_, id] <- Regex.run(~r{/status(?:es)?/(\d+)}, url),
         {:ok, card} <- syndication(id, url) do
      {:ok, card}
    else
      _ -> oembed(url)
    end
  end

  defp syndication(id, url) do
    Req.get(@syndication,
      params: [id: id, token: token(String.to_integer(id)), lang: "en"],
      receive_timeout: 10_000
    )
    |> case do
      {:ok, %{status: 200, body: %{"text" => _} = tweet}} -> {:ok, build_card(tweet, url)}
      _ -> :error
    end
  end

  @doc false
  def build_card(tweet, url) do
    user = tweet["user"] || %{}
    handle = esc(user["screen_name"] || "")

    media =
      (tweet["mediaDetails"] || [])
      |> Enum.filter(&is_binary(&1["media_url_https"]))
      |> Enum.map_join("", fn m ->
        ~s(<img class="tw-media" src="#{esc(m["media_url_https"])}" loading="lazy">)
      end)

    """
    <div class="tw-head">\
    <img class="tw-avatar" src="#{esc(user["profile_image_url_https"] || "")}">\
    <div><span class="tw-name">#{esc(user["name"] || "")}</span>\
    <a class="tw-handle" href="https://x.com/#{handle}">@#{handle}</a></div>\
    </div>\
    <p class="tw-text">#{tweet |> visible_text() |> esc() |> String.replace("\n", "<br>")}</p>\
    #{media}\
    <a class="tw-date" href="#{esc(url)}">#{date(tweet["created_at"])}</a>\
    """
  end

  # the raw text starts with reply mentions and ends with the media
  # t.co link; display_text_range marks the part a reader sees
  defp visible_text(%{"text" => text} = tweet) do
    case tweet["display_text_range"] do
      [a, b] -> text |> String.codepoints() |> Enum.slice(a, b - a) |> Enum.join()
      _ -> text
    end
    |> String.trim()
  end

  defp date(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%b %-d, %Y")
      _ -> ""
    end
  end

  defp date(_), do: ""

  defp esc(s), do: Plug.HTML.html_escape(to_string(s))

  # the token the syndication CDN expects, derived from the id the same
  # way the reference client derives it
  @doc false
  def token(id) do
    x = id / 1.0e15 * :math.pi()
    i = trunc(x)
    base = String.downcase(Integer.to_string(i, 36))
    String.replace(base <> frac36(x - i, 12), "0", "")
  end

  defp frac36(_f, 0), do: ""

  defp frac36(f, n) do
    f = f * 36
    d = trunc(f)
    String.downcase(Integer.to_string(d, 36)) <> frac36(f - d, n - 1)
  end

  defp oembed(url) do
    Req.get(@oembed,
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
