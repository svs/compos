defmodule Compos.Core.MCP.Elicitation do
  @moduledoc """
  MCP form elicitation (2025-06-18 stateful `elicitation/create` and 2026-07-28
  stateless `InputRequiredResult` retry flow used by Google Workspace MCP servers).

  When a server pauses a tool call for user confirmation or structured input,
  this module turns the JSON Schema `requestedSchema` and Markdown `message`
  into one-click question cards via `Compos.Core.Agent.ask_user/3`, maps the
  user's chosen label back to its raw schema value (e.g. `ALLOW_ONCE`,
  `ALLOW_TOOL_ALWAYS`, `DENY_ONCE`), and returns the wire response payload.
  """

  alias Compos.Core.Agent

  @doc """
  Resolve a stateless 2026-07-28 `InputRequiredResult` (`resultType: "input_required"`).
  Returns `{:ok, retry_params}` carrying `inputResponses` (and `requestState`
  when present), or `{:error, reason}` when no UI is available to ask.
  """
  def resolve_stateless(server, tool, result, opts \\ [])

  def resolve_stateless(server, tool, %{"inputRequests" => requests} = result, opts)
      when is_map(requests) and map_size(requests) > 0 do
    request_state = Map.get(result, "requestState")

    resolved =
      requests
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, %{}}, fn {key, req}, {:ok, acc} ->
        params = (is_map(req) && Map.get(req, "params")) || %{}

        case respond_form(server, tool, params, opts) do
          {:ok, response} -> {:cont, {:ok, Map.put(acc, key, response)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case resolved do
      {:ok, responses} ->
        retry = %{"inputResponses" => responses}

        retry =
          if is_binary(request_state),
            do: Map.put(retry, "requestState", request_state),
            else: retry

        {:ok, retry}

      {:error, _} = err ->
        err
    end
  end

  def resolve_stateless(server, tool, _result, _opts) do
    {:error, "#{server} #{tool}: server returned input_required without inputRequests"}
  end

  @doc """
  Resolve a single `elicitation/create` form request. Used directly by stateful
  server-initiated requests (always returns a wire map, falling back to cancel).
  """
  def respond_stateful(server, tool, params, opts \\ []) do
    case respond_form(server, tool, params, opts) do
      {:ok, response} -> response
      {:error, _} -> %{"action" => "cancel"}
    end
  end

  @doc """
  Prompt the user for one `elicitation/create` form and return
  `{:ok, %{"action" => ..., ...}}` or `{:error, msg}`.
  """
  def respond_form(server, tool, params, opts \\ []) when is_map(params) do
    case custom_handler(opts) do
      fun when is_function(fun, 3) ->
        normalize_handler_result(fun.(server, tool, params))

      _ ->
        ask_in_chat(server, tool, params, opts[:slug])
    end
  end

  defp custom_handler(opts) do
    opts[:elicitation_handler] || Application.get_env(:compos_core, :mcp_elicitation_fun)
  end

  defp normalize_handler_result({:ok, map}) when is_map(map), do: {:ok, map}
  defp normalize_handler_result({:error, msg}), do: {:error, to_string(msg)}
  defp normalize_handler_result(map) when is_map(map), do: {:ok, map}
  defp normalize_handler_result(_), do: {:ok, %{"action" => "cancel"}}

  defp ask_in_chat(server, tool, params, slug) do
    if is_binary(slug) and slug != "" and Agent.running?(slug) do
      prompt_schema(slug, server, tool, params)
    else
      {:error,
       "MCP server #{server} requires user confirmation (form elicitation), but no active chat is available to prompt"}
    end
  end

  defp prompt_schema(slug, server, tool, params) do
    header = if is_binary(tool) and tool != "", do: "**#{server} · #{tool}**", else: "**#{server}**"
    message = Map.get(params, "message") || ""
    schema = Map.get(params, "requestedSchema") || %{}
    properties = Map.get(schema, "properties") || %{}
    required = Map.get(schema, "required") || []

    if map_size(properties) == 0 do
      question = join_blocks([header, message])

      case Agent.ask_user(slug, question, ["Allow", "Decline"]) do
        {:ok, "Allow"} -> {:ok, %{"action" => "accept", "content" => %{}}}
        {:ok, _} -> {:ok, %{"action" => "decline"}}
        {:error, _} -> {:ok, %{"action" => "cancel"}}
      end
    else
      fields = ordered_fields(properties, required)

      fields
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, %{}}, fn {field, idx}, {:ok, acc} ->
        spec = Map.get(properties, field) || %{}
        options = field_options(spec)
        labels = Enum.map(options, &elem(&1, 1))
        title = Map.get(spec, "title") || Map.get(spec, "description")

        question =
          if idx == 0 do
            join_blocks([header, message, title || if(message == "", do: field, else: nil)])
          else
            join_blocks([header, title || field])
          end

        case Agent.ask_user(slug, question, labels) do
          {:ok, answer} ->
            value = resolve_answer(spec, options, answer)
            {:cont, {:ok, Map.put(acc, field, value)}}

          {:error, _} ->
            {:halt, {:ok, %{"action" => "cancel"}}}
        end
      end)
      |> case do
        {:ok, %{"action" => _} = resp} -> {:ok, resp}
        {:ok, content} -> {:ok, %{"action" => "accept", "content" => content}}
      end
    end
  end

  defp ordered_fields(properties, required) do
    req = Enum.filter(required, &Map.has_key?(properties, &1))
    rest = properties |> Map.keys() |> Enum.reject(&(&1 in req)) |> Enum.sort()
    req ++ rest
  end

  defp field_options(%{"enum" => values} = spec) when is_list(values) do
    names = Map.get(spec, "enumNames")

    if is_list(names) and length(names) == length(values) do
      Enum.zip(values, Enum.map(names, &to_string/1))
    else
      Enum.map(values, fn v -> {v, to_string(v)} end)
    end
  end

  defp field_options(%{"oneOf" => entries}) when is_list(entries) do
    entries
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn entry ->
      case Map.fetch(entry, "const") do
        {:ok, val} -> [{val, to_string(Map.get(entry, "title") || val)}]
        :error -> []
      end
    end)
  end

  defp field_options(%{"type" => "boolean"}), do: [{true, "Yes"}, {false, "No"}]
  defp field_options(_), do: []

  defp resolve_answer(spec, [], answer), do: coerce_value(spec, answer)

  defp resolve_answer(spec, options, answer) do
    ans = to_string(answer)
    down = String.downcase(String.trim(ans))

    case Enum.find(options, fn {val, label} ->
           label == ans or to_string(val) == ans or
             String.downcase(label) == down or String.downcase(to_string(val)) == down
         end) do
      {val, _label} -> val
      nil -> coerce_value(spec, ans)
    end
  end

  defp coerce_value(%{"type" => "boolean"}, answer) do
    String.downcase(String.trim(to_string(answer))) in ["true", "yes", "y", "1", "allow"]
  end

  defp coerce_value(%{"type" => "integer"}, answer) do
    case Integer.parse(String.trim(to_string(answer))) do
      {n, ""} -> n
      _ -> to_string(answer)
    end
  end

  defp coerce_value(%{"type" => "number"}, answer) do
    case Float.parse(String.trim(to_string(answer))) do
      {n, ""} -> n
      _ -> to_string(answer)
    end
  end

  defp coerce_value(_, answer), do: to_string(answer)

  defp join_blocks(parts) do
    parts
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n\n")
  end
end
