defmodule Compos.Core.KeyDispatch do
  @moduledoc """
  Key transport. Runs in the *caller's* process (LiveView, test, RPC) —
  never inside Editor or Session — so the Scheme key loop it calls can
  freely use both.

  The loop itself is Scheme: `(key-dispatch! KEY)` in editor.scm routes a
  key to the capture, the minibuffer, the completion popup, a Transient or
  the buffer, accumulates the prefix, inserts a printable, and runs the
  command as a key runs it. What keys *mean* is keymap data.

  Key spec strings follow Emacs: `"a"`, `"C-x"`, `"M-x"`, `"C-M-f"`, `"RET"`,
  `"DEL"`, `"TAB"`, `"SPC"`, `"<left>"`.
  """

  require Logger
  alias Compos.Core.{Buffer, Editor, Frame, Session}

  @doc """
  Dispatch a key for a frame: stamps the frame context so every Editor and
  Session call below resolves against it. nil clears — the key then acts on
  the last-active frame (tests, RPC).
  """
  def handle_key(fid, key) do
    if fid do
      Frame.put(fid)
      # make it the last-active frame and swap its window's point in
      Editor.touch_frame(fid)
    else
      Frame.clear()
    end

    handle_key(key)
  end

  def handle_key(key) do
    case Session.call_named("key-dispatch!", [key], Frame.current(), 30_000, :ui) do
      {:error, msg} -> Logger.warning("key dispatch failed: " <> inspect(msg))
      _ -> :ok
    end

    :ok
  catch
    :exit, {:timeout, _} ->
      Logger.warning("key dispatch timed out: " <> inspect(key))
      :ok

    # the lane worker died under the call (a kill, a code purge): drop the
    # key and keep the client alive
    :exit, reason ->
      Logger.warning("key dispatch failed: " <> inspect(key) <> ": " <> inspect(reason, limit: 5))
      :ok
  end

  @doc """
  An input intent from the browser's text pipeline (`beforeinput`): TYPE is
  the inputType, FROM..TO the byte range it targets (-1 = at point), TEXT
  what it inserts. A collapsed intent at point is the key it stands for and
  takes the key path, so the minibuffer, the keymaps, and completion see it
  as a key. A ranged intent is Scheme policy (`input-intent!`).
  """
  def handle_intent(type, from, to, text), do: handle_intent(type, from, to, text, -1, -1)

  def handle_intent(type, from, to, text, at, v) when is_binary(type) and is_binary(text) do
    snapshot = Editor.snapshot()

    routed? =
      Map.get(snapshot, :minibuffer) != nil or Map.get(snapshot, :completion) != nil or
        Map.get(snapshot, :transient) != nil or Map.get(snapshot, :key_capture) != nil

    buffer = Editor.current_buffer()

    # The reader's caret says where the edit lands, while the DOM it was
    # measured against is the text the server holds. DISABLED until the
    # client can prove the CARET is current, not just the text: beforeinput
    # preventDefaults, so while you type the browser never advances the
    # caret, and trusting a matching version put every keystroke one place
    # back.
    _ = {at, v}
    if false, do: Buffer.goto(buffer, at)

    point = if Buffer.exists?(buffer), do: Buffer.point(buffer), else: 0
    # a collapsed intent acts at point: the byte above has already moved
    # point to the caret whenever the client could prove it was current
    at_point? = from == to
    # a pending prefix (C-c, C-x) waits for its next key. The letter typed
    # over a selection comes as a ranged intent, and it is that key all the
    # same: "C-c i" with a region must not type an i over the region.
    chord? = Map.get(snapshot, :pending, []) != []

    cond do
      (at_point? or chord?) and intent_key(type, text) != nil ->
        handle_key(intent_key(type, text))

      # a routed surface (minibuffer, completion) takes text one key at a
      # time: an input method commits a word, the prompt sees its letters
      routed? and type in ~w(insertText insertReplacementText insertCompositionText) ->
        text |> String.graphemes() |> Enum.each(&handle_key(intent_key("insertText", &1)))

      true ->
        run_intent(type, from, to, text, point)
    end

    :ok
  end

  defp intent_key("insertText", " "), do: "SPC"
  defp intent_key("insertText", "\n"), do: "RET"

  defp intent_key(type, text) when type in ["insertText", "insertReplacementText"] do
    if String.length(text) == 1, do: text, else: nil
  end

  defp intent_key("insertParagraph", _), do: "RET"
  defp intent_key("insertLineBreak", _), do: "RET"
  defp intent_key("deleteContentBackward", _), do: "DEL"
  defp intent_key("deleteContentForward", _), do: "<delete>"
  defp intent_key(_, _), do: nil

  defp run_intent(type, from, to, text, point) do
    {from, to} = if from < 0 or to < 0, do: {point, point}, else: {min(from, to), max(from, to)}
    buffer = Editor.current_buffer()
    if Buffer.exists?(buffer), do: Buffer.break_undo_chain(buffer)

    case Session.call_named("input-intent!", [type, from, to, text]) do
      {:ok, _} ->
        Editor.finish_command("input-intent", false)

      other ->
        Editor.finish_command("input-intent", false)
        Editor.set_echo("input-intent: " <> inspect(other))
    end
  end

  @doc "Narrow the popup to the text between its start and point; Scheme calls this after its own edit."
  def requery_completion do
    case Editor.snapshot().completion do
      %{start: start} ->
        buf = Editor.current_buffer()
        point = Buffer.point(buf)

        if point > start do
          Editor.completion_query(binary_part(Buffer.text(buf), start, point - start))
        else
          Editor.completion_dismiss()
        end

      _ ->
        :ok
    end
  end

  # --- key tracing ------------------------------------------------------------
  # The mechanism under Scheme's (trace-key): the key loop records one row at
  # every phase boundary. Scheme owns the presentation and the derived fields
  # (packages/telemetry.scm).

  @trace :key_trace

  @doc """
  Dispatch KEYS in the calling process and record one row per phase: the
  key, the resolved command, the pre-command policy, and the state after
  the command. Each row is a Scheme plist with the current buffer, point,
  size, and the chat mark locals, so a reader can see which phase moved
  point.
  """
  def trace_keys(keys) do
    Process.put(@trace, [])

    try do
      Enum.each(keys, &handle_key/1)
      Process.get(@trace) |> Enum.reverse()
    after
      Process.delete(@trace)
    end
  end

  # a row per phase, newest first — only while trace_keys/1 is collecting
  @doc "Record one key-trace row while trace_keys/1 collects; Scheme's key loop calls this."
  def trace_note(phase, name) do
    case Process.get(@trace) do
      rows when is_list(rows) ->
        buf = Editor.current_buffer()
        alive = Buffer.exists?(buf)

        row = [
          {:sym, "phase"},
          phase,
          {:sym, "name"},
          name,
          {:sym, "buffer"},
          buf,
          {:sym, "point"},
          if(alive, do: Buffer.point(buf), else: 0),
          {:sym, "size"},
          if(alive, do: Buffer.byte_size(buf), else: 0),
          {:sym, "mark"},
          (alive && Buffer.get_local(buf, "agent-saved-mark")) || false,
          {:sym, "marker-bytes"},
          (alive && Buffer.get_local(buf, "agent-marker-bytes")) || false
        ]

        Process.put(@trace, [row | rows])

      _ ->
        :ok
    end

    :ok
  end
end
