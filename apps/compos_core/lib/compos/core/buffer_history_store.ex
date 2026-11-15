defmodule Compos.Core.BufferHistoryStore do
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

  def dir, do: Path.join(Compos.Core.state_dir(), "docs")

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
        weave = Compos.Core.BufferHistory.new(peer)
        Enum.each(blobs, &Compos.Core.BufferHistory.import(weave, &1))
        weave
    end
  end

  @doc """
  The log of ID as the text of a buffer: `{:ok, document}`, or
  `{:error, reason}` when the log cannot answer for the text. A missing
  file, a file with no whole frame, and a frame the document refuses are
  each an error, never an empty document: a buffer whose checkpoint holds
  no text has nothing else to come back from. A torn tail after whole
  frames is not an error; the frames before it are the history.
  """
  def load_text(id, peer) do
    path = path(id)

    with {:read, {:ok, bin}} <- {:read, File.read(path)},
         {:frames, [_ | _] = blobs} <- {:frames, frames(bin, [])},
         weave = Compos.Core.BufferHistory.new(peer),
         {:import, :ok} <- {:import, import_all(weave, blobs)},
         {:text, text} when is_binary(text) <- {:text, Compos.Core.BufferHistory.text(weave)} do
      {:ok, weave, text}
    else
      {:read, {:error, :enoent}} -> {:error, {:no_log, path}}
      {:read, {:error, posix}} -> {:error, {:unreadable_log, path, posix}}
      {:frames, []} -> {:error, {:no_frames, path}}
      {:import, why} -> {:error, {:corrupt_log, path, why}}
      {:text, why} -> {:error, {:corrupt_log, path, why}}
    end
  rescue
    e -> {:error, {:corrupt_log, path(id), Exception.message(e)}}
  end

  defp import_all(weave, blobs) do
    Enum.reduce_while(blobs, :ok, fn blob, :ok ->
      case Compos.Core.BufferHistory.import(weave, blob) do
        {:error, why} -> {:halt, why}
        _ -> {:cont, :ok}
      end
    end)
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
  #
  # The new log goes to a temporary file and takes the log's name by a
  # rename, so a crash or a full disk leaves the old log whole: a write in
  # place truncates the file first.
  def compact(id, snapshot) when is_binary(snapshot) do
    frame = <<byte_size(snapshot)::size(@frame_bits), snapshot::binary>>
    tmp = path(id) <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- write_file(tmp, frame),
         :ok <- File.rename(tmp, path(id)) do
      byte_size(frame)
    else
      _ ->
        File.rm(tmp)
        0
    end
  end

  defp write_file(file, bytes) do
    File.mkdir_p!(dir())
    File.write(file, bytes, [:binary])
  rescue
    e ->
      Logger.error("could not write #{file}: #{inspect(e)}")
      :error
  end

  def forget(id), do: File.rm(path(id))

  @doc """
  Move the log to the graveyard instead of deleting it. True when a file moved.

  A kill goes through this, never through `forget/1`: the log is the editor's
  write-ahead history, and no editor gesture may erase it.
  """
  def entomb(id) do
    src = path(id)

    if File.exists?(src) do
      dead = Path.join(dir(), "dead")
      File.mkdir_p!(dead)
      File.rename(src, Path.join(dead, id <> ".loro")) == :ok
    else
      false
    end
  rescue
    e ->
      Logger.error("could not entomb the document log for #{id}: #{inspect(e)}")
      false
  end

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
