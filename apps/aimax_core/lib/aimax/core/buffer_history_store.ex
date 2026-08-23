defmodule Aimax.Core.BufferHistoryStore do
  @moduledoc """
  Durable Loro documents, one log file per buffer. See `docs/PROVENANCE-CRDT.md`.

  A buffer checkpoint holds the text. This holds the history behind it: who
  wrote each part, in what order, and what every earlier state was.

  The file is a sequence of length-prefixed blobs. The first is a snapshot and
  the rest are updates, which is what makes the common write cheap: 500 typed
  characters export as about 1.2 KB, while a snapshot of the same 85 KB source
  file is 75 KB. Appending on every checkpoint would be unaffordable at
  snapshot size and is nothing at update size.

  Reading imports every blob in order. Loro accepts a snapshot and an update
  through the same call, so the reader does not care which is which, and
  importing the same bytes twice changes nothing.

  A torn tail is expected rather than exceptional: a crash between the write
  and the flush leaves a partial frame. The reader stops at the first frame it
  cannot trust and keeps everything before it, so a crash costs the last batch
  and never the history.
  """

  require Logger

  @frame_bits 32
  @max_frame 64 * 1024 * 1024

  def dir, do: Path.join(Aimax.Core.home(), "docs")

  def path(id), do: Path.join(dir(), id <> ".loro")

  @doc "Every blob in the log, oldest first. An absent or unreadable log is []."
  def read(id) do
    case File.read(path(id)) do
      {:ok, bin} -> frames(bin, [])
      _ -> []
    end
  end

  defp frames(<<len::size(@frame_bits), rest::binary>>, acc)
       when len > 0 and len <= @max_frame and byte_size(rest) >= len do
    <<blob::binary-size(len), tail::binary>> = rest
    frames(tail, [blob | acc])
  end

  # Anything else is the torn tail, or the clean end of the file.
  defp frames(_partial, acc), do: Enum.reverse(acc)

  @doc """
  The history on disk, as a document, without going near the buffer process.

  This is what survived, rather than what a running buffer would write if
  asked, so it is the honest answer to "is this durable yet".
  """
  def load(id, peer \\ 0) do
    case read(id) do
      [] ->
        nil

      blobs ->
        weave = Aimax.Core.BufferHistory.new(peer)
        Enum.each(blobs, &Aimax.Core.BufferHistory.import(weave, &1))
        weave
    end
  end

  @doc "Append one blob. Returns the bytes written, or 0 on failure."
  def append(id, blob) when is_binary(blob) do
    if blob == "" do
      0
    else
      frame = <<byte_size(blob)::size(@frame_bits), blob::binary>>

      case write(id, frame, [:append]) do
        :ok -> byte_size(frame)
        _ -> 0
      end
    end
  end

  @doc """
  Replace the log with one snapshot. The history is unchanged: a Loro snapshot
  carries it. This only stops the file from growing without bound.
  """
  def compact(id, snapshot) when is_binary(snapshot) do
    frame = <<byte_size(snapshot)::size(@frame_bits), snapshot::binary>>

    case write(id, frame, []) do
      :ok -> byte_size(frame)
      _ -> 0
    end
  end

  def forget(id), do: File.rm(path(id))

  def size(id) do
    case File.stat(path(id)) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp write(id, frame, modes) do
    File.mkdir_p!(dir())
    File.write(path(id), frame, modes)
  rescue
    e ->
      Logger.error("could not write the document log for #{id}: #{inspect(e)}")
      :error
  end
end
