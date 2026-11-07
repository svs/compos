defmodule Compos.Core.ErrorFeed do
  @moduledoc """
  Every error the daemon logs, as a `compos:error` event on the log
  (`Compos.Core.Events`). An `:logger` handler, so it sees what
  `~/.compos/daemon.log` sees, from any process.

  The event's data is `text`, the whole message, and `signature`, the
  message with its numbers, pids and references blanked, in front of the
  module that logged it. Repeats of one fault share a signature. What to do
  with an error is Scheme's (`scheme/packages/self-healing.scm`).

  The handler runs in the process that logged, so it only spawns: the
  append happens elsewhere, and an error in the append is not logged back
  into the feed.
  """

  @id :compos_error_feed
  @max_text 4_000

  # One fault can log thousands of times a second: a descriptor storm
  # logged `emfile` 74,000 times in two minutes, and every one became an
  # event. Each signature publishes at most once a window; the repeats in
  # the window go to daemon.log only.
  @window_ms 10_000
  @table :compos_error_feed_windows
  @holder :compos_error_feed_holder

  @doc "Add the handler; again replaces it. The application calls this at boot."
  def install do
    ensure_table()
    :logger.remove_handler(@id)
    :logger.add_handler(@id, __MODULE__, %{level: :error})
  end

  # The table outlives the caller: a small holder process owns it
  defp ensure_table do
    if Process.whereis(@holder) == nil do
      parent = self()

      pid =
        spawn(fn ->
          if :ets.whereis(@table) == :undefined,
            do: :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

          send(parent, {@holder, :ready})
          Process.sleep(:infinity)
        end)

      try do
        Process.register(pid, @holder)
      rescue
        _ -> Process.exit(pid, :kill)
      end

      receive do
        {@holder, :ready} -> :ok
      after
        1_000 -> :ok
      end
    end

    :ok
  end

  @doc """
  True for the first occurrence of SIGNATURE in the current window, false
  for a repeat. Without the table every occurrence is the first.
  """
  def first_in_window?(signature, now_ms \\ System.monotonic_time(:millisecond)) do
    if :ets.whereis(@table) == :undefined do
      true
    else
      window = div(now_ms, @window_ms)
      key = {signature, window}

      case :ets.update_counter(@table, key, 1, {key, 0}) do
        1 ->
          # a new window for this signature: drop the windows before it
          :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", window}], [true]}])
          true

        _ ->
          false
      end
    end
  end

  @doc false
  def log(%{msg: msg, meta: meta}, _config) do
    unless Map.get(meta, @id) do
      spawn(fn -> publish(msg, meta) end)
    end

    :ok
  end

  defp publish(msg, meta) do
    Logger.metadata([{@id, true}])
    text = msg |> text(meta) |> String.slice(0, @max_text)
    sig = signature(text, meta)
    # a hot reload does not run install again: the first error makes the table
    if :ets.whereis(@table) == :undefined, do: ensure_table()

    if first_in_window?(sig) do
      Compos.Core.Events.publish("compos:error", :logged, %{
        text: text,
        signature: sig,
        source: source(meta)
      })
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "The message with what changes from one occurrence to the next blanked."
  def signature(text, meta \\ %{}) do
    line =
      text
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.replace(~r/#(PID|Reference|Port|Function)<[^>]*>/, "#\\1<>")
      |> String.replace(~r/0x[0-9a-fA-F]+/, "0x")
      |> String.replace(~r/\d+/, "N")
      |> String.slice(0, 200)

    case source(meta) do
      "" -> line
      src -> src <> ": " <> line
    end
  end

  defp source(%{mfa: {m, f, a}}), do: "#{inspect(m)}.#{f}/#{a}"
  defp source(_), do: ""

  defp text({:string, s}, _meta), do: IO.chardata_to_string(s)

  defp text({:report, report}, %{report_cb: cb}) when is_function(cb, 1) do
    {format, args} = cb.(report)
    text({format, args}, %{})
  end

  defp text({:report, report}, _meta), do: inspect(report, limit: 50)

  defp text({format, args}, _meta) do
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  rescue
    _ -> inspect({format, args}, limit: 50)
  end
end
