defmodule Compos.Core.ModelCatalog do
  @moduledoc """
  Normalized model reasoning metadata for every LLM frontend.

  ReqLLM's bundled `LLMDB` is the baseline catalog.  Its newer typed
  reasoning fields are preferred, while the older models.dev
  `extra.reasoning_options` shape remains a necessary fallback until the
  snapshot is fully curated.  Backends with a live catalog (notably Codex
  App Server) normalize through this module too and remain authoritative for
  their own session.

  The result deliberately keeps effort, thinking mode, and token budget as
  separate controls: providers often expose more than one, and collapsing
  them into a single connector-wide "effort" list invents invalid choices.
  """

  @snapshot_home "~/.compos/llm_db"

  @doc """
  Where the refreshed snapshot lives.

  The catalog `llm_db` ships is inside `deps/`, which `mix deps.get` throws
  away, and it ages from the day the dependency was locked. A snapshot this
  editor refreshed belongs outside the build, so it survives a dependency
  update and a rebuild.
  """
  def snapshot_home, do: Path.expand(@snapshot_home)

  def snapshot_file, do: Path.join(snapshot_home(), "snapshot.json")

  def meta_file, do: Path.join(snapshot_home(), "snapshot-meta.json")

  @doc """
  What the loaded catalog is: its id, when it was captured, and how much it
  carries. `stale_days` is what a caller reads to decide to refresh.

  The figures come from the metadata file written beside a refreshed
  snapshot. Without one the editor runs the catalog `llm_db` packaged, whose
  age nothing records, so `stale_days` is nil and `path` says "packaged".
  """
  def snapshot_info do
    case read_meta() do
      %{} = meta ->
        captured = meta["captured_at"]

        %{
          snapshot_id: meta["snapshot_id"],
          captured_at: captured,
          models: meta["model_count"],
          providers: meta["provider_count"],
          stale_days: stale_days(captured),
          path: snapshot_file()
        }

      _ ->
        %{
          snapshot_id: nil,
          captured_at: nil,
          models: nil,
          providers: nil,
          stale_days: nil,
          path: "packaged"
        }
    end
  end

  defp read_meta do
    with true <- File.exists?(snapshot_file()),
         {:ok, body} <- File.read(meta_file()),
         {:ok, meta} <- Jason.decode(body) do
      meta
    else
      _ -> nil
    end
  end

  @doc """
  Fetch the newest published snapshot, keep it, and load it now.

  This runs the network, so a caller gives it a process of its own. It
  returns the same shape as `snapshot_info/0` for the snapshot it installed.
  """
  def refresh do
    case LLMDB.Snapshot.ReleaseStore.fetch_snapshot(:latest) do
      {:ok, %{snapshot: snapshot}} -> install(snapshot)
      {:ok, snapshot} when is_map(snapshot) -> install(snapshot)
      {:error, reason} -> {:error, "catalog fetch failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "catalog fetch failed: #{Exception.message(e)}"}
  end

  @doc """
  Install a snapshot already on disk, instead of fetching one.

  The published catalog comes from the GitHub API, which refuses an
  unauthenticated caller that asks too often. A snapshot kept from an
  earlier fetch installs without the network.
  """
  def install_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, snapshot} <- Jason.decode(body) do
      install(snapshot)
    else
      {:error, reason} -> {:error, "catalog read failed: #{inspect(reason)}"}
    end
  end

  # Install only a snapshot that loads. The order matters: a catalog that
  # fails to load must not be left on disk, or the next boot reads it and
  # the editor comes up with no models at all.
  defp install(snapshot) do
    snapshot = prune_unknown_providers(snapshot)
    path = snapshot_file()
    previous = Application.get_env(:llm_db, :snapshot_path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write_snapshot(path, snapshot),
         :ok <- load_from(path) do
      write_snapshot(meta_file(), LLMDB.Snapshot.metadata(snapshot))
      {:ok, snapshot_info()}
    else
      {:error, reason} ->
        # put the editor back on the catalog it was using
        File.rm(path)
        File.rm(meta_file())
        restore(previous)
        {:error, reason}
    end
  end

  defp load_from(path) do
    Application.put_env(:llm_db, :snapshot_path, path)
    LLMDB.Catalog.clear!()

    case LLMDB.load() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "catalog load failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "catalog load failed: #{Exception.message(e)}"}
  end

  defp restore(nil), do: restore_packaged()
  defp restore(previous), do: (Application.put_env(:llm_db, :snapshot_path, previous); reload())

  defp restore_packaged do
    Application.delete_env(:llm_db, :snapshot_path)
    reload()
  end

  defp reload do
    LLMDB.Catalog.clear!()
    LLMDB.load()
    :ok
  rescue
    _ -> :ok
  end

  # A published snapshot runs ahead of the llm_db we build against: it can
  # name a provider this version has no atom for, and the loader rejects the
  # whole snapshot for one of them. Dropping those providers keeps every
  # provider this editor can actually reach.
  defp prune_unknown_providers(snapshot) do
    case providers_of(snapshot) do
      {key, providers} when is_map(providers) ->
        kept =
          providers
          |> Map.filter(fn {id, _} -> known_provider?(id) end)
          |> Map.new(fn {id, provider} -> {id, prune_unknown_models(provider)} end)

        if kept == providers do
          snapshot
        else
          # the id is an integrity hash of the contents, so a pruned
          # snapshot has to be stamped again or the loader rejects it
          pruned = Map.put(snapshot, key, kept)
          Map.put(pruned, id_key(snapshot), LLMDB.Snapshot.snapshot_id(pruned))
        end

      _ ->
        snapshot
    end
  end

  defp id_key(snapshot) do
    if Map.has_key?(snapshot, :snapshot_id), do: :snapshot_id, else: "snapshot_id"
  end

  defp providers_of(snapshot) when is_map(snapshot) do
    cond do
      is_map(snapshot["providers"]) -> {"providers", snapshot["providers"]}
      is_map(snapshot[:providers]) -> {:providers, snapshot[:providers]}
      true -> nil
    end
  end

  defp providers_of(_), do: nil

  defp known_provider?(id) when is_atom(id), do: true

  defp known_provider?(id) when is_binary(id) do
    case LLMDB.Generated.ProviderRegistry.fetch(id) do
      {:ok, _} ->
        true

      _ ->
        try do
          String.to_existing_atom(id)
          true
        rescue
          ArgumentError -> false
        end
    end
  end

  defp known_provider?(_), do: false

  # Same skew, one level down: a published snapshot can give a model a
  # modality this version has no atom for, and one such model fails the
  # whole load.
  defp prune_unknown_models(provider) when is_map(provider) do
    case models_of(provider) do
      {key, models} when is_map(models) ->
        Map.put(provider, key, Map.filter(models, fn {_, m} -> known_model?(m) end))

      _ ->
        provider
    end
  end

  defp prune_unknown_models(provider), do: provider

  defp models_of(provider) when is_map(provider) do
    cond do
      is_map(provider["models"]) -> {"models", provider["models"]}
      is_map(provider[:models]) -> {:models, provider[:models]}
      true -> nil
    end
  end

  defp models_of(_), do: nil

  defp known_model?(model) when is_map(model) do
    modalities = model["modalities"] || model[:modalities] || %{}

    modalities
    |> Map.values()
    |> List.flatten()
    |> Enum.all?(&known_modality?/1)
  end

  defp known_model?(_), do: true

  defp known_modality?(m) when is_binary(m) or is_atom(m) do
    match?({:ok, _}, LLMDB.Generated.ValidModalities.fetch(m))
  end

  defp known_modality?(_), do: true

  defp write_snapshot(path, snapshot) do
    LLMDB.Snapshot.write!(path, snapshot)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The snapshot's capture instant, parsed by Scheme at build time. A meta
  # file that changed without a rebuild reads as an unknown age.
  defp stale_days(captured) when is_binary(captured) do
    case :ets.lookup(:compos_model_rules, :captured) do
      [{:captured, ^captured, secs}] when is_integer(secs) ->
        div(System.os_time(:second) - secs, 86_400)

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp stale_days(_), do: nil

  @doc """
  Pricing for a model spec, $ per million tokens, or nil when the catalog
  has no cost for it: %{input:, output:, cache_read:, cache_write:}.
  """
  def price(spec) do
    with {:ok, %{cost: %{} = cost}} <- lookup(spec) do
      %{
        input: Map.get(cost, :input),
        output: Map.get(cost, :output),
        cache_read: Map.get(cost, :cache_read) || 0,
        cache_write: Map.get(cost, :cache_write) || 0
      }
    else
      _ -> nil
    end
  end

  @doc """
  The model's own output-token limit from the catalog, or nil.

  A flat cap truncates a long reply on a model that allows far more, and
  the provider reports that truncation as a length stop, which the editor
  then has to show. Meta documents a 128K maximum generated output for the
  Muse Spark family; the catalog carries the context window instead.
  """
  def max_tokens(spec) do
    if String.contains?(spec, "muse-spark-") do
      128 * 1024
    else
      with {:ok, %{limits: %{} = limits}} <- lookup(spec),
           out when is_integer(out) and out > 0 <- Map.get(limits, :output),
           do: out,
           else: (_ -> nil)
    end
  end

  @doc """
  How many input tokens the model accepts, or nil. `limits.input` where the
  catalog states one, else `limits.context`: a model can hold a million
  tokens of context and accept fewer of them as input, and it is the input
  figure a conversation runs into. Compaction reads this.
  """
  def context_limit(spec) do
    with {:ok, %{limits: %{} = limits}} <- lookup(spec),
         n when is_integer(n) and n > 0 <- Map.get(limits, :input) || Map.get(limits, :context),
         do: n,
         else: (_ -> nil)
  end

  @doc "Decode the bundled catalog once, off the request path; any lookup after this is milliseconds."
  def warm do
    lookup("anthropic:claude-sonnet-5")
    :ok
  rescue
    _ -> :ok
  end

  @doc "Reasoning controls for a ReqLLM model spec, or nil when it is unknown."
  def reasoning(model_spec) when is_binary(model_spec) do
    with {:ok, model} <- lookup(model_spec) do
      rules_answer(model)
    else
      _ -> nil
    end
  end

  # The answer Scheme built from the raw entry at the last catalog load
  # (packages/model-rules.scm, model-rules-build!). A lookup reads it; it
  # never calls Scheme.
  defp rules_answer(%{provider: provider, id: id}) do
    case :ets.lookup(:compos_model_rules, Atom.to_string(provider) <> ":" <> id) do
      [{_, answer}] -> answer
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Credential-aware chat model inventory supplied by ReqLLM/LLMDB."
  def available_models do
    ReqLLM.available_models(require: [chat: true])
  rescue
    _ -> []
  end


  @doc """
  The catalog entry for a spec: `provider:id`, or a bare id looked up as
  Anthropic then OpenAI.

  This answers `{:error, :unknown_model}` and never raises. llm_db reads its
  snapshot on the first lookup and raises `LLMDB.LoadError` when the whole
  snapshot fails to deserialize, which one unreadable entry is enough to
  cause. Every caller here wants metadata it can do without, so a catalog
  that will not load reads as a catalog that knows nothing, and chats keep
  working without pricing or a context limit.
  """
  def lookup(spec) do
    lookup!(spec)
  rescue
    _ -> {:error, :unknown_model}
  end

  defp lookup!(spec) do
    case LLMDB.model(spec) do
      {:ok, _} = ok ->
        ok

      _ ->
        cond do
          not is_binary(spec) -> {:error, :unknown_model}
          byte_size(spec) == 0 -> {:error, :unknown_model}
          String.contains?(spec, ":") -> {:error, :unknown_model}
          true -> bare_model(spec)
        end
    end
  end

  # Compos's direct lane intentionally treats a bare id as Anthropic.  Codex
  # model ids are bare too, so OpenAI is the second lookup for catalog-only
  # metadata used before a native session has supplied its live model/list.
  defp bare_model(id) do
    case LLMDB.model(:anthropic, id) do
      {:ok, _} = ok -> ok
      _ -> LLMDB.model(:openai, id)
    end
  end


end
