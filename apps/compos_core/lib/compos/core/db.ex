defmodule Compos.Core.DB do
  @moduledoc """
  Databases: named, long-lived SQL connections.

  Which databases exist, what a query means, and how a result is shown is
  Scheme policy (packages/db.scm); this module is mechanism. Scheme names
  a connection and never sees a pid.

  The wire protocol, authentication, and type decoding are the reason this
  is Elixir. PostgreSQL alone has SCRAM-SHA-256, TLS, and thirty type OIDs
  in two wire formats; a Scheme implementation would be slower and wrong in
  more places. The adapter boundary keeps that from becoming a vendor list:
  an adapter belongs here only when it is a BEAM-native driver that Scheme
  could not supply.

  One connection per name, not a pool. The editor runs queries with little
  concurrency, and a single connection is what makes a scoped transaction
  work: every query through its handle reaches the checked-out session.

  `query/4` never blocks the caller's lane. It answers through a callback,
  the way LSP requests and endpoint asks do. `query/3` is blocking and
  belongs on a worker lane, such as a Morg Scheme task.
  """

  require Logger

  @adapters %{"postgres" => Postgrex, "postgresql" => Postgrex}

  defmodule Transaction do
    @moduledoc false
    @enforce_keys [:name, :owner, :ref]
    defstruct [:name, :owner, :ref]
  end

  @doc "Open a named connection. SPEC picks the adapter and its options."
  def connect(name, spec) when is_binary(name) and is_map(spec) do
    adapter = spec["adapter"] || "postgres"

    cond do
      not Regex.match?(~r/^[a-z0-9._@-]+$/, name) ->
        {:error, "db names are [a-z0-9._@-]: #{name}"}

      not Map.has_key?(@adapters, adapter) ->
        {:error, "unknown db adapter #{inspect(adapter)}; known: #{known_adapters()}"}

      whereis(name) != nil ->
        {:ok, :already}

      true ->
        start_adapter(name, adapter, spec)
    end
  end

  def known_adapters, do: @adapters |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  defp start_adapter(name, adapter, spec) do
    mod = @adapters[adapter]
    opts = adapter_opts(mod, name, spec)

    child = %{
      id: {:db, name},
      start: {mod, :start_link, [opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Compos.Core.DBSupervisor, child) do
      {:ok, pid} ->
        remember(name, %{adapter: adapter, spec: redact(spec)})
        {:ok, pid}

      {:error, reason} ->
        {:error, "db #{name}: #{inspect(reason)}"}
    end
  end

  # A unix socket needs socket_dir; a host needs hostname. PostgreSQL on a
  # developer machine usually listens on the socket only, so the spec that
  # names neither gets the socket.
  defp adapter_opts(Postgrex, name, spec) do
    base = [
      name: {:via, Registry, {Compos.Core.DBRegistry, name}},
      database: spec["database"] || spec["name"] || "postgres",
      pool_size: 1,
      # a query that cannot finish must fail the callback, not wedge the lane
      timeout: int(spec["timeout"], 15_000),
      # the driver retries a dropped connection on its own; keep the gap
      # short so an editor query after a server restart just works
      backoff_type: :rand_exp
    ]

    base
    |> put_if(:username, spec["user"] || spec["username"])
    |> put_if(:password, spec["password"])
    |> put_if(:port, int_or_nil(spec["port"]))
    |> socket_or_host(spec)
    |> put_if(:ssl, ssl_opt(spec["ssl"]))
  end

  defp socket_or_host(opts, spec) do
    cond do
      spec["socket_dir"] -> Keyword.put(opts, :socket_dir, spec["socket_dir"])
      spec["socket"] -> Keyword.put(opts, :socket, spec["socket"])
      spec["host"] -> Keyword.put(opts, :hostname, spec["host"])
      true -> Keyword.put(opts, :socket_dir, default_socket_dir())
    end
  end

  defp default_socket_dir, do: System.get_env("PGHOST") || "/tmp"

  defp ssl_opt(nil), do: nil
  defp ssl_opt(false), do: nil
  defp ssl_opt("false"), do: nil
  defp ssl_opt(_), do: [verify: :verify_none]

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp int(n, _d) when is_integer(n), do: n
  defp int(_, d), do: d

  defp int_or_nil(n) when is_integer(n), do: n

  defp int_or_nil(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int_or_nil(_), do: nil

  # what a connection's detail may show: never the password
  defp redact(spec), do: Map.drop(spec, ["password"])

  def disconnect(name) do
    case whereis(name) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(Compos.Core.DBSupervisor, pid)
        :persistent_term.erase({:compos_db, name})
        :ok
    end
  end

  def whereis(name) do
    case Registry.lookup(Compos.Core.DBRegistry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def connections do
    Registry.select(Compos.Core.DBRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
    |> Enum.map(fn name ->
      r = last(name) || %{adapter: "?", spec: %{}}
      %{name: name, adapter: r.adapter, database: r.spec["database"] || ""}
    end)
  end

  @doc """
  Run SQL with bound parameters. CB receives {:ok, result} | {:error, msg}.

  The query runs in a task so the caller's lane stays free; the driver
  serializes it against the connection's other work.
  """
  def query(name, sql, params, cb) when is_function(cb, 1) do
    case whereis(name) do
      nil ->
        cb.({:error, "db: no connection #{name}"})
        :ok

      pid ->
        Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
          cb.(run(pid, sql, params))
        end)

        :ok
    end
  end

  @doc "Run SQL on the calling process. The caller must choose a non-UI lane."
  def query(%Transaction{} = transaction, sql, params) do
    with :ok <- active_transaction(transaction) do
      run(Process.get(transaction_key(transaction.ref)), sql, params)
    end
  end

  def query(name, sql, params) do
    case whereis(name) do
      nil -> {:error, "db: no connection #{name}"}
      pid -> run(pid, sql, params)
    end
  end

  @doc "Run FUN with a scoped transaction handle and return its value."
  def with_transaction(name, fun) when is_function(fun, 1) do
    case whereis(name) do
      nil ->
        {:error, "db: no connection #{name}"}

      pid ->
        case Postgrex.transaction(pid, fn conn -> in_transaction(name, conn, fun) end) do
          {:ok, result} -> {:ok, result}
          {:error, msg} -> {:error, to_string(msg)}
        end
    end
  catch
    :exit, _ -> {:error, "db: connection is not available"}
  end

  defp in_transaction(name, conn, fun) do
    transaction = %Transaction{name: name, owner: self(), ref: make_ref()}
    Process.put(transaction_key(transaction.ref), conn)

    try do
      fun.(transaction)
    after
      Process.delete(transaction_key(transaction.ref))
    end
  end

  defp active_transaction(%Transaction{owner: owner}) when owner != self(),
    do: {:error, "db: transaction belongs to another execution lane"}

  defp active_transaction(%Transaction{ref: ref}) do
    if Process.get(transaction_key(ref)),
      do: :ok,
      else: {:error, "db: transaction is no longer active"}
  end

  defp transaction_key(ref), do: {__MODULE__, :transaction, ref}

  defp run(pid, sql, params) do
    case Postgrex.query(pid, sql, params) do
      {:ok, %Postgrex.Result{} = r} ->
        {:ok,
         %{
           columns: r.columns || [],
           rows: r.rows || [],
           num_rows: r.num_rows || 0,
           command: to_string(r.command || "")
         }}

      {:error, %Postgrex.Error{postgres: pg}} when is_map(pg) ->
        {:error, pg_error(pg)}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  catch
    :exit, _ -> {:error, "db: connection is not available"}
  end

  # The fields the README promised: SQLSTATE, message, detail, hint, position.
  # :pg_code is the SQLSTATE digits; :code is Postgrex's atom name for it,
  # and a caller matching on an error wants the digits.
  defp pg_error(pg) do
    [
      pg[:pg_code] && "#{pg[:pg_code]}",
      pg[:code] && "#{pg[:code]}",
      pg[:message],
      pg[:detail] && "detail: #{pg[:detail]}",
      pg[:hint] && "hint: #{pg[:hint]}",
      pg[:position] && "position: #{pg[:position]}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" — ")
  end

  def remember(name, record), do: :persistent_term.put({:compos_db, name}, record)
  def last(name), do: :persistent_term.get({:compos_db, name}, nil)
end
