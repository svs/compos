defmodule Aimax.Core.Keys do
  @moduledoc """
  One API-key lookup for every integration (LLM providers, MCP servers):
  env var -> ~/.aimax/<name>-key -> doppler (project personal / config dev,
  same source as ~/.emacs.d/secrets.el). Doppler results are cached in
  :persistent_term — including misses, so a missing doppler binary costs
  one spawn per var, not one per request.
  """

  def get(var) do
    with nil <- non_empty(System.get_env(var)),
         nil <- file_key(var) do
      doppler_key(var)
    end
  end

  defp non_empty(s) when s in [nil, ""], do: nil
  defp non_empty(s), do: s

  defp file_key(var) do
    name = var |> String.replace("_API_KEY", "") |> String.downcase()

    case File.read(Path.join(Aimax.Core.home(), "#{name}-key")) do
      {:ok, key} -> non_empty(String.trim(key))
      _ -> nil
    end
  end

  defp doppler_key(var) do
    cache_key = {:aimax_doppler, var}

    case :persistent_term.get(cache_key, :unset) do
      :unset ->
        key =
          case System.cmd(
                 "doppler",
                 ["secrets", "get", var, "--project", "personal", "--config", "dev", "--plain"],
                 stderr_to_stdout: true
               ) do
            {out, 0} -> non_empty(String.trim(out))
            _ -> nil
          end

        :persistent_term.put(cache_key, key)
        key

      cached ->
        cached
    end
  rescue
    # doppler binary missing
    _ -> nil
  end
end
