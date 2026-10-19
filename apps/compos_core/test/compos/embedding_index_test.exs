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

  test "catalog sync persists vectors and foreground search embeds only the query", %{path: path} do
    texts = [
      "function buffer-kill! Kill buffer B and remove its working copy.",
      "function load-theme Apply a named color theme."
    ]

    opts = [path: path, dimensions: 2]

    assert {:ok, 2} = EmbeddingIndex.sync(texts, "test-key", opts)

    assert_receive {:embedding_request, sync_request}
    assert sync_request["model"] == "text-embedding-3-small"
    assert sync_request["dimensions"] == 2
    assert sync_request["input"] == texts

    assert {:ok, [{0, first_score}, {1, second_score}]} =
             EmbeddingIndex.search("remove the current document", texts, "test-key", opts)

    assert first_score > second_score
    assert File.exists?(path)
    cache_bytes = File.read!(path)
    refute cache_bytes =~ "test-key"
    refute cache_bytes =~ "buffer-kill!"

    assert_receive {:embedding_request, query_request}
    assert query_request["input"] == ["remove the current document"]

    assert {:ok, [{0, _}, {1, _}]} =
             EmbeddingIndex.search("remove the current document", texts, "test-key", opts)

    refute_receive {:embedding_request, _}

    EmbeddingIndex.forget_memory(path)

    assert {:ok, [{0, _}, {1, _}]} =
             EmbeddingIndex.search("remove the current document", texts, "test-key", opts)

    assert_receive {:embedding_request, disk_request}
    assert disk_request["input"] == ["remove the current document"]

    changed = [hd(texts), "function load-theme Apply a changed color theme."]

    assert {:ok, [{0, _}]} =
             EmbeddingIndex.search("remove the current document", changed, "test-key", opts)

    refute_receive {:embedding_request, _}

    assert {:ok, 1} = EmbeddingIndex.sync(changed, "test-key", opts)
    assert_receive {:embedding_request, changed_request}
    assert changed_request["input"] == ["function load-theme Apply a changed color theme."]

    assert :ok = EmbeddingIndex.clear(path)
    refute File.exists?(path)

    assert {:ok, []} =
             EmbeddingIndex.search("remove the current document", changed, "test-key", opts)

    refute_receive {:embedding_request, _}

    assert {:ok, 2} = EmbeddingIndex.sync(changed, "test-key", opts)
    assert_receive {:embedding_request, rebuilt_request}
    assert rebuilt_request["input"] == changed
  end

  test "a generation is gathered once, and an unknown query never reaches the network",
       %{path: path} do
    texts = [
      "function buffer-kill! Kill buffer B and remove its working copy.",
      "function load-theme Apply a named color theme."
    ]

    opts = [path: path, dimensions: 2, gen: 7]
    assert {:ok, 2} = EmbeddingIndex.sync(texts, "test-key", opts)
    assert_receive {:embedding_request, _sync}

    # a query nobody has asked has no vector, and this caller will not wait
    # for one: it says so instead of embedding on the spot
    assert {:error, :absent} =
             EmbeddingIndex.search(
               "remove the current document",
               texts,
               "test-key",
               opts ++ [cached_only: true]
             )

    refute_receive {:embedding_request, _}, 100

    # asked for real, it embeds once and the generation is gathered
    assert {:ok, [{0, _}, {1, _}]} =
             EmbeddingIndex.search("remove the current document", texts, "test-key", opts)

    assert_receive {:embedding_request, query_request}
    assert query_request["input"] == ["remove the current document"]

    # now the caller may keep its texts at home: the generation names them
    assert {:ok, [{0, _}, {1, _}]} =
             EmbeddingIndex.search(
               "remove the current document",
               [],
               "test-key",
               opts ++ [cached_only: true]
             )

    # a generation the index never gathered cannot be answered from nothing
    assert {:error, :not_prepared} =
             EmbeddingIndex.search(
               "remove the current document",
               [],
               "test-key",
               path: path,
               dimensions: 2,
               gen: 8,
               cached_only: true
             )
  end

  test "a smaller corpus keeps the vectors it left out" do
    root = Path.join(System.tmp_dir!(), "compos-embedding-#{System.unique_integer([:positive])}")
    path = Path.join(root, "apropos.etf")
    on_exit(fn -> EmbeddingIndex.forget_memory(path) end)
    opts = [path: path, dimensions: 2]

    kill = "function buffer-kill! Kill buffer B and remove its working copy."
    theme = "function load-theme Apply a named color theme."

    # a package is loaded: both entries embed once
    assert {:ok, 2} = EmbeddingIndex.sync([kill, theme], "k", opts)
    assert_receive {:embedding_request, _}

    # the package is unloaded, and a search runs against what is left
    assert {:ok, 0} = EmbeddingIndex.sync([kill], "k", opts)
    refute_receive {:embedding_request, _}

    # the package is loaded again. Its text did not change, so its vector is
    # still the one already paid for: loading a library embeds nothing.
    assert {:ok, 0} = EmbeddingIndex.sync([kill, theme], "k", opts)
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
             EmbeddingIndex.sync(["catalog row"], "test-key",
               path: path,
               dimensions: 2
             )
  end

  # As float lists, the vectors made every sync copy about 60 MB into the
  # literal area, and the literal area filled and stopped the VM.
  test "the cache keeps each vector as one off-heap binary", %{path: path} do
    texts = ["function buffer-kill! Kill buffer B.", "function load-theme Apply a theme."]
    opts = [path: path, dimensions: 2]

    assert {:ok, 2} = EmbeddingIndex.sync(texts, "test-key", opts)

    %{vectors: vectors} = :erlang.binary_to_term(File.read!(path))
    assert map_size(vectors) == 2
    assert Enum.all?(Map.values(vectors), &(is_binary(&1) and byte_size(&1) == 16))
  end

  test "a cache file of float lists still answers without embedding again", %{path: path} do
    texts = ["function buffer-kill! Kill buffer B.", "function load-theme Apply a theme."]
    opts = [path: path, dimensions: 2]
    assert {:ok, 2} = EmbeddingIndex.sync(texts, "test-key", opts)
    assert_receive {:embedding_request, _}

    old = :erlang.binary_to_term(File.read!(path))

    lists =
      Map.new(old.vectors, fn {hash, bin} ->
        {hash, for(<<x::float-64-native <- bin>>, do: x)}
      end)

    File.write!(path, :erlang.term_to_binary(%{old | vectors: lists}))
    EmbeddingIndex.forget_memory(path)
    EmbeddingIndex.forget_prepared(opts)

    assert {:ok, 0} = EmbeddingIndex.sync(texts, "test-key", opts)
    refute_receive {:embedding_request, _}

    assert {:ok, [{0, first}, {1, second}]} =
             EmbeddingIndex.search("remove the current document", texts, "test-key", opts)

    assert first > second
  end
end
