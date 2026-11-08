defmodule Compos.OpenRouterCacheTest do
  @moduledoc """
  OpenRouter caches an Anthropic model at cache_control marks on the content.
  Which model gets marks is Scheme's (llm-request-plan, llm-gate-test.scm).
  """
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

  @marks %{"cache" => {:sym, "marks"}, "ttl" => "1h"}

  test "a marks plan marks the system prompt and the newest message" do
    marked = LLM.cache_marks(ctx(), @marks)
    assert marks(marked) == [{:system, "SYS"}, {:user, "again"}]
  end

  test "the marks reach the request openrouter sends" do
    marked = LLM.cache_marks(ctx(), @marks)
    {:ok, model} = ReqLLM.model("openrouter:anthropic/claude-sonnet-5")
    {:ok, req} = ReqLLM.Providers.OpenRouter.prepare_request(:chat, model, marked, api_key: "x")
    body = ReqLLM.Providers.OpenRouter.build_body(req)
    json = Jason.encode!(body[:messages] || body["messages"])
    assert length(String.split(json, "cache_control")) == 3
  end

  test "a plan without marks leaves the context alone" do
    assert marks(LLM.cache_marks(ctx(), %{"cache" => false, "ttl" => "1h"})) == []
    assert marks(LLM.cache_marks(ctx(), %{"cache" => {:sym, "options"}, "ttl" => "1h"})) == []
  end
end
