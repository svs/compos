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

  @doc "Reasoning controls for a ReqLLM model spec, or nil when it is unknown."
  def reasoning(model_spec) when is_binary(model_spec) do
    with {:ok, model} <- lookup(model_spec) do
      normalize_reasoning(model.capabilities || %{}, model.extra || %{}, "llmdb")
    else
      _ -> nil
    end
  end

  @doc "Credential-aware chat model inventory supplied by ReqLLM/LLMDB."
  def available_models do
    ReqLLM.available_models(require: [chat: true])
  rescue
    _ -> []
  end

  @doc "Normalize one model returned by Codex App Server's `model/list`."
  def codex_model(model) when is_map(model) do
    efforts =
      model
      |> get("supportedReasoningEfforts", [])
      |> Enum.map(&codex_effort/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    default = string(get(model, "defaultReasoningEffort"))

    %{
      "id" => string(get(model, "model")) || string(get(model, "id")) || "",
      "name" => string(get(model, "displayName")) || "",
      "reasoning" =>
        if(efforts == [],
          do: nil,
          else: %{
            "enabled" => true,
            "effort" => %{"values" => efforts, "default" => default},
            "source" => "backend"
          }
        )
    }
  end

  @doc "Compact live-backend entry consumed by the Scheme model picker."
  def picker_entry(model) when is_map(model) do
    normalized = codex_model(model)
    effort = get_in(normalized, ["reasoning", "effort"]) || %{}

    [
      normalized["id"],
      normalized["name"],
      Map.get(effort, "values", []),
      Map.get(effort, "default") || ""
    ]
  end

  defp lookup(spec) do
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

  defp normalize_reasoning(capabilities, extra, source) do
    reasoning = get(capabilities, :reasoning, %{}) || %{}
    raw = get(extra, "reasoning_options", []) || []

    effort = typed_effort(reasoning) || raw_effort(raw)
    thinking = typed_thinking(reasoning) || raw_toggle(raw)
    token_budget = typed_budget(reasoning) || raw_budget(raw)

    enabled =
      get(reasoning, :enabled, false) == true or effort != nil or thinking != nil or
        token_budget != nil

    if enabled do
      %{
        "enabled" => true,
        "effort" => effort,
        "thinking" => thinking,
        "token_budget" => token_budget,
        "source" => source
      }
    end
  end

  defp typed_effort(reasoning) do
    effort = get(reasoning, :effort)
    values = if is_map(effort), do: strings(get(effort, :values, [])), else: []

    if is_map(effort) and get(effort, :supported, false) == true and values != [] do
      %{"values" => values, "default" => string(get(effort, :default))}
    end
  end

  defp raw_effort(options) do
    case Enum.find(options, &(get(&1, "type") == "effort")) do
      nil ->
        nil

      option ->
        case strings(get(option, "values", [])) do
          [] -> nil
          values -> %{"values" => values, "default" => string(get(option, "default"))}
        end
    end
  end

  defp typed_thinking(reasoning) do
    thinking = get(reasoning, :thinking)
    types = if is_map(thinking), do: strings(get(thinking, :types, [])), else: []

    if is_map(thinking) and get(thinking, :supported, false) == true do
      %{
        "types" => types,
        "default" => string(get(thinking, :default_type)),
        "disable_supported" => get(thinking, :disable_supported)
      }
    end
  end

  defp raw_toggle(options) do
    if Enum.any?(options, &(get(&1, "type") == "toggle")) do
      %{"types" => ["enabled"], "default" => nil, "disable_supported" => true}
    end
  end

  defp typed_budget(reasoning) do
    case get(reasoning, :token_budget) do
      value when is_integer(value) -> %{"min" => 0, "max" => value, "default" => value}
      value when is_map(value) -> budget_map(value)
      _ -> nil
    end
  end

  defp raw_budget(options) do
    case Enum.find(options, &(get(&1, "type") == "budget_tokens")) do
      nil -> nil
      option -> budget_map(option)
    end
  end

  defp budget_map(value) do
    result = %{
      "min" => get(value, :min),
      "max" => get(value, :max),
      "default" => get(value, :default)
    }

    if Enum.any?(result, fn {_key, value} -> is_integer(value) end), do: result
  end

  defp codex_effort(value) when is_binary(value), do: value

  defp codex_effort(value) when is_map(value) do
    string(get(value, "reasoningEffort")) || string(get(value, "effort")) ||
      string(get(value, "value"))
  end

  defp codex_effort(_), do: nil

  defp strings(values) when is_list(values), do: Enum.flat_map(values, &List.wrap(string(&1)))
  defp strings(_), do: []

  defp string(value) when is_binary(value), do: value
  defp string(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp string(_), do: nil

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp get(_value, _key, default), do: default
end
