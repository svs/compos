defmodule Compos.OpenRouterCacheTest do
  @moduledoc "OpenRouter caches an Anthropic model at cache_control marks on the content."
  use ExUnit.Case, async: true

  alias Compos.Core.LLM

  defp ctx do
    ReqLLM.Context.new([
      ReqLLM.Context.system("SYS"),
      ReqLLM.Context.user("hi"),
      ReqLLM.Context.assistant("yo"),
      ReqLLM.Context.user("again")
    ])
  end

  defp marks(ctx) do
    for m <- ctx.messages, p <- m.content, Map.has_key?(p.metadata || %{}, :cache_control),
        do: {m.role, p.text}
  end

  test "an anthropic model through openrouter marks the system prompt and the newest message" do
    marked = LLM.openrouter_cache_marks(ctx(), "openrouter:anthropic/claude-sonnet-5")
    assert marks(marked) == [{:system, "SYS"}, {:user, "again"}]
  end

  test "the marks reach the request openrouter sends" do
    marked = LLM.openrouter_cache_marks(ctx(), "openrouter:anthropic/claude-sonnet-5")
    {:ok, model} = ReqLLM.model("openrouter:anthropic/claude-sonnet-5")
    {:ok, req} = ReqLLM.Providers.OpenRouter.prepare_request(:chat, model, marked, api_key: "x")
    body = ReqLLM.Providers.OpenRouter.build_body(req)
    json = Jason.encode!(body[:messages] || body["messages"])
    assert length(String.split(json, "cache_control")) == 3
  end

  test "another model gets no marks" do
    assert marks(LLM.openrouter_cache_marks(ctx(), "openrouter:openai/gpt-5.5")) == []
    assert marks(LLM.openrouter_cache_marks(ctx(), "anthropic:claude-sonnet-5")) == []
  end
end
