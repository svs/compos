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

  @doc "Add the handler; again replaces it. The application calls this at boot."
  def install do
    :logger.remove_handler(@id)
    :logger.add_handler(@id, __MODULE__, %{level: :error})
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

    Compos.Core.Events.publish("compos:error", :logged, %{
      text: text,
      signature: signature(text, meta),
      source: source(meta)
    })
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
