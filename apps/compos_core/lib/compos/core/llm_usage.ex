defmodule Compos.Core.LLMUsage do
  @moduledoc """
  The tokens and the price of one usage map, for a chat's own running
  total (the backend `usage` event). Prices come from
  `Compos.Core.ModelCatalog`.

  The ledger is not here. Every backend reports its usage as it got it
  (`Compos.Core.LLM.report_usage/2`), and the llm-costs package prices it
  and keeps llm-usage.jsonl.
  """

  @doc """
  Dollars for a usage map (Anthropic or OpenAI field names), nil when the
  model is unpriced.

  A usage map that carries its own "cost" wins. That is req_llm's figure,
  priced against its model database from the provider's raw numbers.

  The fallback stays for the models req_llm prices at nothing: a model
  missing from its database, or a lane that reports usage without a cost.
  It prices `input_tokens` at the input rate and the cached tokens at the
  cache rate, which is right because `LLM.usage_strings/2` normalizes
  every provider to one shape first: `input_tokens` means FRESH input.
  Before that, an OpenAI request billed each cached token twice — once
  inside the input count, once at the cache rate.
  """
  def cost(_model, %{"cost" => c}) when is_number(c), do: c

  def cost(model, usage) do
    case Compos.Core.ModelCatalog.price(model) do
      nil ->
        nil

      p ->
        %{input: i, output: o, cache_read: cr, cache_write: cw} = tokens(usage)

        (i * (p.input || 0) + o * (p.output || 0) + cr * p.cache_read + cw * p.cache_write) /
          1_000_000
    end
  end

  @doc "Normalize a usage map to %{input:, output:, cache_read:, cache_write:} token counts."
  def tokens(usage) do
    %{
      input: usage["input_tokens"] || usage["prompt_tokens"] || 0,
      output: usage["output_tokens"] || usage["completion_tokens"] || 0,
      cache_read: usage["cache_read_input_tokens"] || 0,
      cache_write: usage["cache_creation_input_tokens"] || 0
    }
  end
end
