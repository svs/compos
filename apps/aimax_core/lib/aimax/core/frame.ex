defmodule Aimax.Core.Frame do
  @moduledoc """
  The calling process's frame context. Input and Session stamp the
  dispatching frame into the process dictionary; Editor calls made without
  an explicit frame resolve through `current/0`, and the Editor server falls
  back to the last-active frame when the caller has no context (timers,
  agent events, RPC eval).
  """

  @key :aimax_frame

  @doc "The caller's frame id, or nil (Editor resolves nil to last-active)."
  def current, do: Process.get(@key)

  def put(fid), do: Process.put(@key, fid)
  def clear, do: Process.delete(@key)

  @doc "Run fun with the frame context set, restoring the previous one after."
  def with_frame(fid, fun) do
    prev = Process.get(@key)
    Process.put(@key, fid)

    try do
      fun.()
    after
      if prev, do: Process.put(@key, prev), else: Process.delete(@key)
    end
  end
end
