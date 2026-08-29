defmodule Compos.EmbeddingIndexTest do
  use ExUnit.Case, async: false

  alias Compos.Core.EmbeddingIndex

  setup do
    root = Path.join(System.tmp_dir!(), "compos-embedding-#{System.unique_integer([:positive])}")
    path = Path.join(root, "apropos.etf")
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test_pid, {:embedding_request, request})

      data =
        request["input"]
        |> Enum.with_index()
        |> Enum.map(fn {text, index} ->
          vector =
            cond do
              text == "remove the current document" -> [1.0, 0.0]
              String.contains?(text, "buffer-kill!") -> [0.99, 0.01]
              String.contains?(text, "theme") -> [0.0, 1.0]
              true -> [0.5, 0.5]
            end

          %{"index" => index, "embedding" => vector}
        end)

      Req.Test.json(conn, %{"data" => data, "model" => request["model"]})
    end

    Application.put_env(:compos_core, :embedding_req_options, plug: plug)

    on_exit(fn ->
      Application.delete_env(:compos_core, :embedding_req_options)
      EmbeddingIndex.forget_memory(path)
      File.rm_rf!(root)
    end)

    %{path: path}
  end

  test "OpenAI vectors rank semantic catalog text and persist by content hash", %{path: path} do
    texts = [
      "function buffer-kill! Kill buffer B and remove its working copy.",
      "function load-theme Apply a named color theme."
    ]

    opts = [path: path, dimensions: 2]

    assert {:ok, [{0, first_score}, {1, second_score}]} =
             EmbeddingIndex.search("remove the current document", texts, "test-key", opts)

    assert first_score > second_score
    assert File.exists?(path)
    cache_bytes = File.read!(path)
    refute cache_bytes =~ "test-key"
    refute cache_bytes =~ "buffer-kill!"

    assert_receive {:embedding_request, request}
    assert request["model"] == "text-embedding-3-small"
    assert request["dimensions"] == 2
    assert length(request["input"]) == 3

    assert {:ok, [{0, _}, {1, _}]} =
             EmbeddingIndex.search("remove the current document", texts, "test-key", opts)

    refute_receive {:embedding_request, _}

    EmbeddingIndex.forget_memory(path)

    assert {:ok, [{0, _}, {1, _}]} =
             EmbeddingIndex.search("remove the current document", texts, "test-key", opts)

    assert_receive {:embedding_request, disk_request}
    assert disk_request["input"] == ["remove the current document"]

    changed = [hd(texts), "function load-theme Apply a changed color theme."]

    assert {:ok, [{0, _}, {1, _}]} =
             EmbeddingIndex.search("remove the current document", changed, "test-key", opts)

    assert_receive {:embedding_request, changed_request}
    assert changed_request["input"] == ["function load-theme Apply a changed color theme."]

    assert :ok = EmbeddingIndex.clear(path)
    refute File.exists?(path)

    assert {:ok, [{0, _}, {1, _}]} =
             EmbeddingIndex.search("remove the current document", changed, "test-key", opts)

    assert_receive {:embedding_request, rebuilt_request}
    assert length(rebuilt_request["input"]) == 3
  end

  test "a smaller corpus keeps the vectors it left out" do
    root = Path.join(System.tmp_dir!(), "compos-embedding-#{System.unique_integer([:positive])}")
    path = Path.join(root, "apropos.etf")
    on_exit(fn -> EmbeddingIndex.forget_memory(path) end)
    opts = [path: path, dimensions: 2]

    kill = "function buffer-kill! Kill buffer B and remove its working copy."
    theme = "function load-theme Apply a named color theme."

    # a package is loaded: both entries embed once
    assert {:ok, _} = EmbeddingIndex.search("remove the current document", [kill, theme], "k", opts)
    assert_receive {:embedding_request, _}

    # the package is unloaded, and a search runs against what is left
    assert {:ok, _} = EmbeddingIndex.search("remove the current document", [kill], "k", opts)
    refute_receive {:embedding_request, _}

    # the package is loaded again. Its text did not change, so its vector is
    # still the one already paid for: loading a library embeds nothing.
    assert {:ok, _} = EmbeddingIndex.search("remove the current document", [kill, theme], "k", opts)
    refute_receive {:embedding_request, _}
  end

  test "an API failure leaves lexical fallback available", %{path: path} do
    Application.put_env(:compos_core, :embedding_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "nope"}})
      end
    )

    assert {:error, {:http, 429, "nope"}} =
             EmbeddingIndex.search("query", ["catalog row"], "test-key",
               path: path,
               dimensions: 2
             )
  end
end
