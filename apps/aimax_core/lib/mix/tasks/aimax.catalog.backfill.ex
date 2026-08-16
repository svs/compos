defmodule Mix.Tasks.Aimax.Catalog.Backfill do
  @moduledoc """
  Ask Luna to classify the legacy Scheme catalog.

      mix aimax.catalog.backfill
      mix aimax.catalog.backfill --socket ~/.aimax/sock --batch-size 120

  The task reads the live catalog and provider key through ai-max's JSON-RPC
  socket, then sends docs and bounded source excerpts to Luna. It accepts only
  the closed domain/effect schema and writes one deterministic JSON artifact.
  Runtime discovery never calls an LLM.
  """

  use Mix.Task

  alias Aimax.Core.LLM

  @shortdoc "Backfill catalog metadata with Luna"
  @model "openai:gpt-5.6-luna"
  @levels ~w(pure read write destroy)
  @modifiers ~w(external execute spend)
  @domains ~w(
    agents browser buffers chat code customize discovery editing files help
    interaction mail mcp media org packages processes projects search secrets
    syntax ui vcs windows writing
  )

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          batch_size: :integer,
          output: :string,
          model: :string,
          socket: :string,
          dry_run: :boolean
        ]
      )

    model = opts[:model] || @model
    batch_size = opts[:batch_size] || 120
    socket_path = opts[:socket] || System.get_env("AIMAX_SOCK") || Path.expand("~/.aimax/sock")

    output =
      opts[:output] ||
        Path.expand("../../../priv/catalog-backfill.json", __DIR__)

    socket = connect_rpc!(socket_path)
    entries = corpus(socket)

    if opts[:dry_run] do
      :gen_tcp.close(socket)
      Mix.shell().info("read #{length(entries)} bundled catalog entries over JSON-RPC")
    else
      run_backfill!(socket, entries, model, batch_size, output)
    end
  end

  defp run_backfill!(socket, entries, model, batch_size, output) do
    case Application.ensure_all_started(:req_llm) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("could not start req_llm: #{inspect(reason)}")
    end

    {key_var, key} = provider_key!(socket, model)
    previous_model = LLM.model()
    LLM.set_model(model)

    answers =
      try do
        entries
        |> Enum.chunk_every(batch_size)
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {batch, number} ->
          Mix.shell().info("Luna batch #{number}: #{length(batch)} entries")
          LLM.with_provider_key(key_var, key, fn -> classify_batch!(batch) end)
        end)
      after
        LLM.set_model(previous_model)
        :gen_tcp.close(socket)
      end

    result = merge_answers!(entries, answers, model)
    File.write!(output, Jason.encode_to_iodata!(result, pretty: true))
    Mix.shell().info("wrote #{length(result)} classifications to #{output}")
  end

  defp corpus(socket) do
    count = rpc_json!(socket, "(length (catalog))")

    0..(count - 1)
    |> Enum.map(&rpc_json!(socket, "(nth #{&1} (catalog))"))
    |> Enum.reject(&(&1["origin"] == "user" or &1["package"] == "user"))
    |> Enum.uniq_by(&id/1)
    |> Enum.map(fn entry ->
      Map.take(entry, ~w(kind name qualified-name package doc signature sig use props example))
      |> Map.put("id", id(entry))
      |> Map.put("source", source_excerpt(socket, entry))
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp id(entry), do: "#{entry["kind"]}:#{entry["qualified-name"] || entry["name"]}"

  defp source_excerpt(socket, %{"kind" => kind, "name" => name})
       when kind in ["function", "command", "mode"] do
    encoded_name = Base.encode64(name)

    socket
    |> rpc_value!("(describe-function (string->symbol (base64-decode \"#{encoded_name}\")))")
    |> to_string()
    |> String.slice(0, 1_600)
  end

  defp source_excerpt(socket, %{"kind" => "component", "qualified-name" => name}) do
    encoded_name = Base.encode64(name)

    socket
    |> rpc_json!("(describe-component (string->symbol (base64-decode \"#{encoded_name}\")))")
    |> Jason.encode!()
    |> String.slice(0, 1_600)
  end

  defp source_excerpt(_socket, _entry), do: ""

  defp connect_rpc!(path) do
    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
           :binary,
           active: false,
           packet: :raw
         ]) do
      {:ok, socket} -> socket
      {:error, reason} -> Mix.raise("ai-max RPC unavailable at #{path}: #{inspect(reason)}")
    end
  end

  defp rpc_json!(socket, expression) do
    socket
    |> rpc_value!("(json-encode #{expression})")
    |> Jason.decode!()
  end

  defp rpc_value!(socket, expression) when is_port(socket) do
    request = %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: "eval",
      params: %{code: "(base64-encode #{expression})"}
    }

    :ok = :gen_tcp.send(socket, [Jason.encode!(request), "\n"])

    with {:ok, line} <- recv_line(socket),
         {:ok, %{"result" => printed}} <- Jason.decode(line),
         {:ok, encoded} when is_binary(encoded) <- Jason.decode(printed),
         {:ok, value} <- Base.decode64(encoded) do
      value
    else
      {:ok, %{"error" => error}} -> Mix.raise("ai-max RPC error: #{error["message"]}")
      other -> Mix.raise("invalid ai-max RPC response: #{inspect(other)}")
    end
  end

  defp recv_line(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, chunk} ->
        line = acc <> chunk
        if String.ends_with?(line, "\n"), do: {:ok, line}, else: recv_line(socket, line)

      error ->
        error
    end
  end

  defp provider_key!(socket, model) do
    var =
      case String.split(model, ":", parts: 2) |> hd() do
        "openai" -> "OPENAI_API_KEY"
        "openrouter" -> "OPENROUTER_API_KEY"
        _ -> "ANTHROPIC_API_KEY"
      end

    key = rpc_value!(socket, "(or (key-get \"#{var}\") \"\")")
    if key == "", do: Mix.raise("live ai-max has no #{var}")
    {var, key}
  end

  defp classify_batch!(batch, attempt \\ 1, correction \\ nil) do
    correction_instruction =
      if correction do
        "Your previous answer was rejected: #{correction}. Return a corrected full batch."
      else
        ""
      end

    prompt = """
    Classify ai-max Scheme catalog entries. Return JSON only: one array item
    per input item, in the same order. Do not omit or add ids.

    Each output item must have exactly:
    {"id": string, "domain": string, "effects": [string], "confidence": number}

    domain must be one of: #{Enum.join(@domains, ", ")}.
    effects must contain exactly one level: #{Enum.join(@levels, ", ")}.
    It may also contain: #{Enum.join(@modifiers, ", ")}.

    pure: depends only on arguments and changes no state.
    read: observes state and changes no durable or editor state.
    write: changes state in a normally reversible way.
    destroy: deletes, overwrites, discards, or can lose user work.
    external: communicates outside ai-max.
    execute: evaluates code or starts a process.
    spend: can consume paid resources.

    Classify behavior, not spelling. Moving point or changing a window is
    write. Undoable text edits are write, not destroy. Components are pure.
    Use the primary subject as domain. kind is never a domain.

    #{correction_instruction}

    INPUT:
    #{Jason.encode!(batch)}
    """

    case LLM.request(prompt) do
      {:ok, text} ->
        try do
          text |> decode_json!() |> validate_batch!(batch)
        rescue
          error in Mix.Error ->
            if attempt < 3 do
              Mix.shell().info(
                "Luna repair #{attempt} for rejected batch: #{Exception.message(error)}"
              )

              classify_batch!(batch, attempt + 1, Exception.message(error))
            else
              reraise error, __STACKTRACE__
            end
        end

      {:error, reason} ->
        Mix.raise("Luna request failed: #{reason}")
    end
  end

  defp decode_json!(text) do
    json =
      case Regex.run(~r/```(?:json)?\s*(.*?)\s*```/s, text) do
        [_, fenced] -> fenced
        _ -> text
      end

    case Jason.decode(json) do
      {:ok, value} when is_list(value) -> value
      {:ok, _} -> Mix.raise("Luna returned JSON that was not an array")
      {:error, error} -> Mix.raise("Luna returned invalid JSON: #{Exception.message(error)}")
    end
  end

  defp validate_batch!(answers, batch) do
    expected = Enum.map(batch, & &1["id"])
    actual = Enum.map(answers, & &1["id"])

    if actual != expected, do: Mix.raise("Luna changed, omitted, or reordered catalog ids")

    Enum.each(answers, fn answer ->
      domain = answer["domain"]
      effects = answer["effects"] || []
      levels = Enum.filter(effects, &(&1 in @levels))

      unless domain in @domains, do: Mix.raise("invalid domain for #{answer["id"]}: #{domain}")
      unless levels |> length() == 1, do: Mix.raise("invalid effect level for #{answer["id"]}")

      unless Enum.all?(effects, &(&1 in (@levels ++ @modifiers))),
        do: Mix.raise("invalid effect for #{answer["id"]}")

      unless is_number(answer["confidence"]),
        do: Mix.raise("missing confidence for #{answer["id"]}")
    end)

    answers
  end

  defp merge_answers!(entries, answers, model) do
    by_id = Map.new(answers, &{&1["id"], &1})

    Enum.map(entries, fn entry ->
      answer = Map.fetch!(by_id, entry["id"])

      %{
        "id" => entry["id"],
        "kind" => entry["kind"],
        "name" => entry["name"],
        "qualified_name" => entry["qualified-name"],
        "package" => entry["package"],
        "domain" => answer["domain"],
        "effects" => answer["effects"],
        "confidence" => answer["confidence"],
        "model" => model
      }
    end)
  end
end
