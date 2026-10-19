defmodule Compos.Core.EmbeddingIndex do
  @moduledoc """
  OpenAI embeddings for small local discovery indexes.

  Catalog vectors persist by content hash. Query vectors stay in bounded
  memory. Catalog synchronization is separate from query search, so a
  foreground lookup never waits while changed catalog entries embed.
  """

  require Logger

  @default_model "text-embedding-3-small"
  @default_dimensions 256
  @batch_size 256
  @batch_concurrency 4
  @query_cache_limit 128
  # A query embeds one short string. A caller that waits for it holds a
  # lane, so the query path gives up long before the catalog sync does.
  @query_timeout 8_000
  @cache_version 1
  # persistent_term keys carry this tag. Tag 2 holds packed vectors; a hot
  # reload must not read a tag-1 entry, which holds float lists.
  @term_tag 2
  @endpoint "https://api.openai.com/v1/embeddings"

  @type score :: {non_neg_integer(), float()}

  @doc "Embed QUERY only and score the catalog vectors already synchronized."
  @spec search(String.t(), [String.t()], String.t(), keyword()) ::
          {:ok, [score()]} | {:error, term()}
  def search(query, texts, api_key, opts \\ [])

  def search(query, texts, api_key, opts)
      when is_binary(query) and is_list(texts) and is_binary(api_key) do
    if api_key == "" do
      {:error, :missing_api_key}
    else
      opts = Keyword.put_new(opts, :receive_timeout, @query_timeout)
      model = Keyword.get(opts, :model, @default_model)
      dimensions = Keyword.get(opts, :dimensions, @default_dimensions)
      path = Keyword.get(opts, :path, cache_path())

      query_hash = content_hash(model, dimensions, query)
      query_cache = :persistent_term.get({__MODULE__, @term_tag, :queries, path}, %{})
      available = prepared(texts, model, dimensions, path, Keyword.get(opts, :gen))

      cond do
        available == :not_prepared ->
          {:error, :not_prepared}

        available == [] ->
          {:ok, []}

        # Everything this query needs is already known: score it here and
        # now. The lock below serialises callers that would embed the same
        # text twice, and taking it here made a warm running off-lane block
        # the very query it was warming FOR.
        Map.has_key?(query_cache, query_hash) ->
          {:ok, score(Map.fetch!(query_cache, query_hash), available)}

        Keyword.get(opts, :cached_only, false) ->
          {:error, :absent}

        true ->
          :global.trans({{__MODULE__, :query, path, query_hash}, self()}, fn ->
            do_search(query, texts, api_key, model, dimensions, path, opts)
          end)
      end
    end
  end

  defp score(query_vector, available) do
    available
    |> Enum.map(fn {index, vector} -> {index, cosine(query_vector, vector)} end)
    |> Enum.sort_by(fn {_index, score} -> -score end)
  end

  def search(_, _, _, _), do: {:error, :invalid_arguments}

  @doc "Embed catalog texts missing from the durable content-addressed index."
  @spec sync([String.t()], String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync(texts, api_key, opts \\ [])

  def sync(texts, api_key, opts) when is_list(texts) and is_binary(api_key) do
    if api_key == "" do
      {:error, :missing_api_key}
    else
      model = Keyword.get(opts, :model, @default_model)
      dimensions = Keyword.get(opts, :dimensions, @default_dimensions)
      path = Keyword.get(opts, :path, cache_path())

      :global.trans({{__MODULE__, :catalog, path}, self()}, fn ->
        do_sync(texts, api_key, model, dimensions, path, opts)
      end)
    end
  end

  def sync(_, _, _), do: {:error, :invalid_arguments}

  @doc "Return the persistent embedding cache path."
  def cache_path, do: Path.join([Compos.Core.home(), "cache", "apropos-embeddings.etf"])

  @doc false
  def forget_memory(path \\ cache_path()) do
    :persistent_term.erase({__MODULE__, @term_tag, :disk, path})
    :persistent_term.erase({__MODULE__, @term_tag, :queries, path})
    :ok
  end

  @doc "Delete persistent and in-memory vectors so the next sync rebuilds them."
  def clear(path \\ cache_path()) do
    :global.trans({{__MODULE__, :catalog, path}, self()}, fn ->
      forget_memory(path)
      File.rm(path)
      :ok
    end)
  end

  # The corpus side of a query never changes between two queries of the same
  # catalog generation: the same texts hash to the same vectors. Hashing
  # eighteen hundred strings and gathering their vectors on every lookup was
  # the whole cost of a repeated query. Prepare it once per generation and a
  # query is the cosine pass alone.
  defp prepared(texts, model, dimensions, path, gen) do
    key = {__MODULE__, @term_tag, :prepared, path, model, dimensions}

    case :persistent_term.get(key, :missing) do
      %{gen: ^gen, available: available} when not is_nil(gen) ->
        available

      # the caller kept its texts because it believed this generation was
      # ready, and it is not: say so rather than score against nothing
      _ when texts == [] ->
        :not_prepared

      _ ->
        cache = load_cache(path, model, dimensions)

        available =
          texts
          |> Enum.map(&to_string/1)
          |> Enum.map(&content_hash(model, dimensions, &1))
          |> Enum.with_index()
          |> Enum.flat_map(fn {hash, index} ->
            case Map.fetch(cache.vectors, hash) do
              {:ok, vector} -> [{index, vector}]
              :error -> []
            end
          end)

        if gen, do: :persistent_term.put(key, %{gen: gen, available: available})
        available
    end
  end

  @doc "Forget the prepared corpus matrix; the next query rebuilds it."
  def forget_prepared(opts \\ []) do
    path = Keyword.get(opts, :path, cache_path())
    model = Keyword.get(opts, :model, @default_model)
    dimensions = Keyword.get(opts, :dimensions, @default_dimensions)
    :persistent_term.erase({__MODULE__, @term_tag, :prepared, path, model, dimensions})
    :ok
  end

  # Only reached when the query has no vector yet, under the lock that keeps
  # two callers from buying the same embedding twice. Another caller may have
  # bought it while we waited, so the cache is read again here.
  defp do_search(query, texts, api_key, model, dimensions, path, opts) do
    query_hash = content_hash(model, dimensions, query)
    query_cache = :persistent_term.get({__MODULE__, @term_tag, :queries, path}, %{})
    available = prepared(texts, model, dimensions, path, Keyword.get(opts, :gen))

    if available == [] or available == :not_prepared do
      {:ok, []}
    else
      missing =
        if Map.has_key?(query_cache, query_hash),
          do: %{},
          else: %{query_hash => query}

      with {:ok, fresh} <- embed_missing(missing, api_key, model, dimensions, opts) do
        query_vector = Map.get(fresh, query_hash) || Map.fetch!(query_cache, query_hash)
        put_query(path, query_hash, query_vector, query_cache)
        {:ok, score(query_vector, available)}
      else
        {:error, reason} = error ->
          Logger.warning("apropos query embedding unavailable: #{inspect(reason)}")
          error
      end
    end
  rescue
    error -> embedding_error("query", error)
  end

  defp do_sync(texts, api_key, model, dimensions, path, opts) do
    texts = Enum.map(texts, &to_string/1)
    hashes = Enum.map(texts, &content_hash(model, dimensions, &1))
    cache = load_cache(path, model, dimensions)

    missing =
      hashes
      |> Enum.zip(texts)
      |> Enum.reject(fn {hash, _text} -> Map.has_key?(cache.vectors, hash) end)
      |> Map.new()

    with {:ok, fresh} <- embed_missing(missing, api_key, model, dimensions, opts) do
      if map_size(fresh) > 0 do
        # Keep every vector already paid for. A package can unload and load
        # again without embedding the same content a second time.
        write_cache!(path, model, dimensions, Map.merge(cache.vectors, fresh))
        # the prepared matrix was gathered before these vectors existed, so
        # it names fewer entries than the catalog now has
        forget_prepared(path: path, model: model, dimensions: dimensions)
      end

      {:ok, map_size(fresh)}
    else
      {:error, reason} = error ->
        Logger.warning("apropos catalog embeddings unavailable: #{inspect(reason)}")
        error
    end
  rescue
    error -> embedding_error("catalog", error)
  end

  defp embedding_error(part, error) do
    Logger.warning("apropos #{part} embedding cache failed: #{Exception.message(error)}")
    {:error, error}
  end

  defp embed_missing(missing, _key, _model, _dimensions, _opts) when map_size(missing) == 0,
    do: {:ok, %{}}

  defp embed_missing(missing, api_key, model, dimensions, opts) do
    missing
    |> Enum.chunk_every(@batch_size)
    |> Task.async_stream(
      fn batch ->
        hashes = Enum.map(batch, &elem(&1, 0))
        inputs = Enum.map(batch, &elem(&1, 1))
        {hashes, request(inputs, api_key, model, dimensions, opts)}
      end,
      max_concurrency: @batch_concurrency,
      ordered: true,
      timeout: Keyword.get(opts, :receive_timeout, 30_000) + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {hashes, {:ok, vectors}}}, {:ok, acc} when length(vectors) == length(hashes) ->
        {:cont, {:ok, Map.merge(acc, Map.new(Enum.zip(hashes, Enum.map(vectors, &pack/1))))}}

      {:ok, {_hashes, {:ok, _vectors}}}, _acc ->
        {:halt, {:error, :invalid_embedding_count}}

      {:ok, {_hashes, {:error, _} = error}}, _acc ->
        {:halt, error}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:embedding_task, reason}}}
    end)
  end

  defp request(inputs, api_key, model, dimensions, opts) do
    req_opts =
      [
        url: Keyword.get(opts, :endpoint, @endpoint),
        headers: [{"authorization", "Bearer #{api_key}"}],
        json: %{
          "model" => model,
          "input" => inputs,
          "dimensions" => dimensions,
          "encoding_format" => "float"
        },
        receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
      ] ++ Application.get_env(:compos_core, :embedding_req_options, [])

    case Req.post(req_opts) do
      {:ok, %{status: status, body: %{"data" => data}}} when status in 200..299 ->
        vectors =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, vectors}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, api_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_error(%{"error" => %{"message" => message}}), do: message
  defp api_error(body), do: inspect(body)

  defp content_hash(model, dimensions, text) do
    :crypto.hash(:sha256, [model, 0, Integer.to_string(dimensions), 0, text])
  end

  defp cosine(left, right) do
    {dot, l2, r2} = cosine_sums(left, right, 0.0, 0.0, 0.0)
    if l2 == 0.0 or r2 == 0.0, do: 0.0, else: dot / (:math.sqrt(l2) * :math.sqrt(r2))
  end

  defp cosine_sums(
         <<l::float-64-native, left::binary>>,
         <<r::float-64-native, right::binary>>,
         dot,
         l2,
         r2
       ),
       do: cosine_sums(left, right, dot + l * r, l2 + l * l, r2 + r * r)

  defp cosine_sums(_, _, dot, l2, r2), do: {dot, l2, r2}

  # A vector is one binary of float64s. A binary this size lives off the
  # process heap, so persistent_term keeps a reference and not a copy. As
  # float lists, every sync copied about 60 MB into the literal area, and
  # the 1 GB literal area filled and stopped the VM.
  defp pack(vector) when is_binary(vector), do: vector

  defp pack(vector) when is_list(vector),
    do: for(x <- vector, into: <<>>, do: <<x / 1::float-64-native>>)

  defp pack_all(vectors), do: Map.new(vectors, fn {hash, vector} -> {hash, pack(vector)} end)

  defp load_cache(path, model, dimensions) do
    key = {__MODULE__, @term_tag, :disk, path}

    case :persistent_term.get(key, :missing) do
      %{model: ^model, dimensions: ^dimensions} = cache ->
        cache

      _ ->
        cache = read_cache(path, model, dimensions)
        :persistent_term.put(key, cache)
        cache
    end
  end

  defp read_cache(path, model, dimensions) do
    with {:ok, binary} <- File.read(path),
         %{version: @cache_version, model: ^model, dimensions: ^dimensions, vectors: vectors}
         when is_map(vectors) <- :erlang.binary_to_term(binary, [:safe]) do
      %{model: model, dimensions: dimensions, vectors: pack_all(vectors)}
    else
      _ -> %{model: model, dimensions: dimensions, vectors: %{}}
    end
  rescue
    _ -> %{model: model, dimensions: dimensions, vectors: %{}}
  end

  defp write_cache!(path, model, dimensions, vectors) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    bytes =
      :erlang.term_to_binary(%{
        version: @cache_version,
        model: model,
        dimensions: dimensions,
        vectors: vectors
      })

    File.write!(tmp, bytes, [:binary])
    File.rename!(tmp, path)

    :persistent_term.put(
      {__MODULE__, @term_tag, :disk, path},
      %{model: model, dimensions: dimensions, vectors: vectors}
    )
  end

  defp put_query(path, hash, vector, cache) do
    cache =
      if map_size(cache) >= @query_cache_limit and not Map.has_key?(cache, hash) do
        Map.delete(cache, cache |> Map.keys() |> hd())
      else
        cache
      end

    cache = Map.put(cache, hash, vector)

    :persistent_term.put({__MODULE__, @term_tag, :queries, path}, cache)
  end
end
