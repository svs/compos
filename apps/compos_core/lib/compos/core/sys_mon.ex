defmodule Compos.Core.SysMon do
  @moduledoc """
  Samples of the VM and the host for the `*perf*` buffer.

  This module is mechanism. It reads the BEAM counters and os_mon, keeps
  the previous sample so it can report rates, and returns Scheme plists.
  The Scheme package `perf.scm` decides what to show and how.

  Rates need the previous counters. They live in one public ETS table
  that a small holder process owns, so a lane worker that dies does not
  take the table with it. `persistent_term` is the wrong place: every
  update of a persistent term scans every process.
  """

  @table :compos_sysmon
  @holder :compos_sysmon_holder

  # --- the sample --------------------------------------------------------------

  @doc """
  One sample of the VM and the host as a Scheme plist.

  Percentages are integers 0..100. Rates are integers per second. Byte
  counts are integers. The first sample after boot reports zero rates.
  """
  def sample do
    ensure_wall_time()
    now = System.monotonic_time(:millisecond)
    wall = :erlang.statistics(:scheduler_wall_time_all) |> Enum.sort()
    {reds, _} = :erlang.statistics(:reductions)
    {{:input, io_in}, {:output, io_out}} = :erlang.statistics(:io)
    {gcs, gc_words, _} = :erlang.statistics(:garbage_collection)
    {ctx, _} = :erlang.statistics(:context_switches)
    {uptime, _} = :erlang.statistics(:wall_clock)

    raw = %{
      time: now,
      wall: wall,
      reds: reds,
      io_in: io_in,
      io_out: io_out,
      gcs: gcs,
      gc_words: gc_words,
      ctx: ctx
    }

    last = swap(:sample, raw)
    dt = if last, do: max(now - last.time, 1), else: 0
    utils = utilization(wall, last && last.wall)
    normal = :erlang.system_info(:schedulers)
    dirty_cpu = :erlang.system_info(:dirty_cpu_schedulers)
    {sched, rest} = Enum.split(utils, normal)
    {dcpu, dio} = Enum.split(rest, dirty_cpu)
    memory = :erlang.memory()

    to_plist(%{
      uptime_ms: uptime,
      host: hostname(),
      node: to_string(node()),
      otp: to_string(:erlang.system_info(:otp_release)),
      logical_processors: int_or_zero(:erlang.system_info(:logical_processors)),
      schedulers: sched,
      dirty_cpu: dcpu,
      dirty_io: dio,
      sched_util: mean(sched),
      dirty_cpu_util: mean(dcpu),
      dirty_io_util: mean(dio),
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      process_count: :erlang.system_info(:process_count),
      port_count: :erlang.system_info(:port_count),
      atom_count: :erlang.system_info(:atom_count),
      ets_count: length(:ets.all()),
      reductions_rate: rate(reds, last && last.reds, dt),
      context_switch_rate: rate(ctx, last && last.ctx, dt),
      gc_rate: rate(gcs, last && last.gcs, dt),
      gc_words_rate: rate(gc_words, last && last.gc_words, dt),
      io_in_rate: rate(io_in, last && last.io_in, dt),
      io_out_rate: rate(io_out, last && last.io_out, dt),
      memory: %{
        total: memory[:total],
        processes: memory[:processes],
        system: memory[:system],
        atom: memory[:atom],
        binary: memory[:binary],
        code: memory[:code],
        ets: memory[:ets]
      },
      os: os_sample()
    })
  end

  # scheduler utilization since the previous sample, one integer percent
  # per scheduler; a first sample reports zeros
  defp utilization(wall, nil), do: Enum.map(wall, fn _ -> 0 end)

  defp utilization(wall, last) do
    previous = Map.new(last, fn {id, active, total} -> {id, {active, total}} end)

    Enum.map(wall, fn {id, active, total} ->
      case previous do
        %{^id => {a0, t0}} when total > t0 -> div((active - a0) * 100, total - t0) |> clamp()
        _ -> 0
      end
    end)
  end

  defp clamp(v), do: v |> max(0) |> min(100)

  defp mean([]), do: 0
  defp mean(xs), do: div(Enum.sum(xs), length(xs))

  defp rate(_now, nil, _dt), do: 0
  defp rate(now, then, dt) when dt > 0, do: div(max(now - then, 0) * 1000, dt)
  defp rate(_now, _then, _dt), do: 0

  defp ensure_wall_time do
    if :erlang.system_flag(:scheduler_wall_time, true) == false do
      # the flag was off: the first sample has no baseline. Nothing to do,
      # the next sample reports real numbers.
      :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "localhost"
    end
  end

  # os_mon: each reader is guarded, because the application can be down
  # in a test or a release without it. A missing value reads as 0. The
  # calls go through apply: os_mon belongs to compos_ui, so this app
  # cannot name its modules at compile time.
  defp os_sample do
    %{
      cpu_util: guard(fn -> os(:cpu_sup, :util) |> round() |> clamp() end, 0),
      load1: guard(fn -> load(os(:cpu_sup, :avg1)) end, "0.00"),
      load5: guard(fn -> load(os(:cpu_sup, :avg5)) end, "0.00"),
      load15: guard(fn -> load(os(:cpu_sup, :avg15)) end, "0.00"),
      mem_total: guard(fn -> os_mem(:total) end, 0),
      mem_free: guard(fn -> os_mem(:free) end, 0),
      disks:
        guard(
          fn ->
            for {id, kb, pct} <- os(:disksup, :get_disk_data) do
              %{id: to_string(id), kbytes: kb, pct: clamp(pct)}
            end
          end,
          []
        )
    }
  end

  defp os(module, fun), do: apply(module, fun, [])

  defp load(avg) when is_integer(avg) do
    :erlang.float_to_binary(avg / 256, decimals: 2)
  end

  defp os_mem(which) do
    data = os(:memsup, :get_system_memory_data)

    case which do
      :total -> data[:system_total_memory] || data[:total_memory] || 0
      :free -> data[:available_memory] || data[:free_memory] || 0
    end
  end

  defp guard(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  defp int_or_zero(v) when is_integer(v), do: v
  defp int_or_zero(_), do: 0

  # --- processes ---------------------------------------------------------------

  @info_keys [
    :registered_name,
    :reductions,
    :memory,
    :message_queue_len,
    :status,
    :current_function,
    :initial_call
  ]

  @sorts %{"reds" => :reds, "memory" => :memory, "queue" => :queue, "name" => :name}

  @doc """
  The processes that match FILTER, sorted by SORT, at most LIMIT rows.

  SORT is one of "reds", "memory", "queue", or "name". FILTER is a
  substring of the name or the pid; "" matches every process. `reds` is
  the reductions per second since the previous call, so the first call
  reports zeros. The result is a plist with `rows`, `count` (every
  process) and `matched` (every process the filter kept).
  """
  def processes(limit, sort, filter) when is_integer(limit) do
    now = System.monotonic_time(:millisecond)
    last_time = get(:processes_time)
    dt = if last_time, do: max(now - last_time, 1), else: 0
    put(:processes_time, now)
    filter = String.downcase(filter || "")
    sort = Map.get(@sorts, sort || "reds", :reds)

    rows =
      for pid <- Process.list(), info = Process.info(pid, @info_keys), info != nil do
        reds = info[:reductions]
        then = get({:reds, pid})
        put({:reds, pid}, reds)
        name = process_name(pid, info)

        %{
          pid: pid_string(pid),
          name: name,
          reds: if(then, do: rate(reds, then, dt), else: 0),
          reds_total: reds,
          memory: info[:memory],
          queue: info[:message_queue_len],
          status: to_string(info[:status]),
          current: mfa(info[:current_function])
        }
      end

    prune(rows)

    matched =
      if filter == "" do
        rows
      else
        Enum.filter(rows, fn r ->
          String.contains?(String.downcase(r.name), filter) or String.contains?(r.pid, filter)
        end)
      end

    shown =
      matched
      |> sort_rows(sort)
      |> Enum.take(max(limit, 0))

    to_plist(%{rows: shown, count: length(rows), matched: length(matched)})
  end

  defp sort_rows(rows, :name), do: Enum.sort_by(rows, &String.downcase(&1.name))
  defp sort_rows(rows, key), do: Enum.sort_by(rows, &{-Map.fetch!(&1, key), &1.pid})

  # forget the reductions of processes that are gone
  defp prune(rows) do
    live = MapSet.new(rows, & &1.pid)

    for {{:reds, pid} = key, _} <- :ets.tab2list(table()),
        not MapSet.member?(live, pid_string(pid)) do
      :ets.delete(table(), key)
    end

    :ok
  end

  defp process_name(pid, info) do
    case info[:registered_name] do
      name when is_atom(name) and name != nil and name != [] ->
        inspect(name)

      _ ->
        case initial_call(pid, info[:initial_call]) do
          {m, f, a} -> "#{inspect(m)}.#{f}/#{a}"
          _ -> "?"
        end
    end
  end

  # proc_lib processes (GenServer, Task, Supervisor) hide their real entry
  # point behind proc_lib:init_p; the translation reads the process dictionary
  defp initial_call(pid, {:proc_lib, :init_p, _}) do
    case :proc_lib.translate_initial_call(pid) do
      {_, _, _} = mfa -> mfa
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp initial_call(_pid, {_, _, _} = mfa), do: mfa
  defp initial_call(_pid, _), do: nil

  defp mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp mfa(_), do: ""

  @doc "Everything Process.info tells about PID, as a plist; #f for a dead pid."
  def process_info(pid_text) when is_binary(pid_text) do
    with {:ok, pid} <- parse_pid(pid_text),
         info when is_list(info) <-
           Process.info(pid, [
             :registered_name,
             :initial_call,
             :current_function,
             :status,
             :message_queue_len,
             :messages,
             :links,
             :monitors,
             :monitored_by,
             :trap_exit,
             :priority,
             :reductions,
             :memory,
             :heap_size,
             :total_heap_size,
             :stack_size,
             :garbage_collection,
             :group_leader,
             :dictionary
           ]) do
      dict = info[:dictionary] || []

      to_plist(%{
        pid: pid_text,
        name: process_name(pid, info),
        registered: registered(info[:registered_name]),
        initial_call: mfa(initial_call(pid, info[:initial_call])),
        current: mfa(info[:current_function]),
        status: to_string(info[:status]),
        queue: info[:message_queue_len],
        messages: info[:messages] |> Enum.take(5) |> Enum.map(&inspect(&1, limit: 12, printable_limit: 80)),
        links: length(info[:links] || []),
        monitors: length(info[:monitors] || []),
        monitored_by: length(info[:monitored_by] || []),
        trap_exit: info[:trap_exit] == true,
        priority: to_string(info[:priority]),
        reductions: info[:reductions],
        memory: info[:memory],
        heap_words: info[:heap_size],
        total_heap_words: info[:total_heap_size],
        stack_words: info[:stack_size],
        minor_gcs: Keyword.get(info[:garbage_collection] || [], :minor_gcs, 0),
        group_leader: pid_string(info[:group_leader]),
        ancestors: dict |> Keyword.get(:"$ancestors", []) |> Enum.map(&ancestor/1)
      })
    else
      _ -> false
    end
  end

  defp registered(name) when is_atom(name) and name != nil, do: inspect(name)
  defp registered(_), do: ""

  defp ancestor(a) when is_atom(a), do: inspect(a)
  defp ancestor(p) when is_pid(p), do: pid_string(p)
  defp ancestor(other), do: inspect(other)

  @doc "Exit PID with reason kill. Returns true when the pid parsed and was alive."
  def kill(pid_text) when is_binary(pid_text) do
    case parse_pid(pid_text) do
      {:ok, pid} ->
        alive = Process.alive?(pid)
        if alive, do: Process.exit(pid, :kill)
        alive

      _ ->
        false
    end
  end

  defp pid_string(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> to_string()
  defp pid_string(_), do: ""

  defp parse_pid(text) do
    text = String.trim(text)
    text = if String.starts_with?(text, "<"), do: text, else: "<#{text}>"
    {:ok, :erlang.list_to_pid(String.to_charlist(text))}
  rescue
    _ -> :error
  end

  # --- the previous sample -----------------------------------------------------

  defp swap(key, value) do
    old = get(key)
    put(key, value)
    old
  end

  defp get(key) do
    case :ets.lookup(table(), key) do
      [{^key, value}] -> value
      _ -> nil
    end
  end

  defp put(key, value), do: :ets.insert(table(), {key, value})

  # the table lives in a holder process that only waits; a second caller
  # that races the first finds the table on its retry
  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        start_holder()
        table()

      tid ->
        tid
    end
  end

  defp start_holder do
    parent = self()

    pid =
      spawn(fn ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
          Process.register(self(), @holder)
          send(parent, {:sysmon_table, :ok})
          hold()
        rescue
          _ -> send(parent, {:sysmon_table, :exists})
        end
      end)

    receive do
      {:sysmon_table, _} -> :ok
    after
      1_000 -> Process.exit(pid, :kill)
    end
  end

  # the table dies with the holder; the holder only sleeps
  defp hold do
    receive do
      :stop -> :ok
    end
  end

  # --- Scheme values -----------------------------------------------------------

  @doc "A map as a Scheme plist: keys become symbols, underscores become dashes."
  def to_plist(map) when is_map(map) do
    Enum.flat_map(map, fn {k, v} -> [{:sym, key(k)}, value(v)] end)
  end

  defp key(k), do: k |> to_string() |> String.replace("_", "-")

  defp value(v) when is_map(v), do: to_plist(v)
  defp value(v) when is_list(v), do: Enum.map(v, &value/1)
  defp value(nil), do: false
  defp value(v) when is_atom(v) and v not in [true, false], do: to_string(v)
  defp value(v), do: v
end
