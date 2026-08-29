defmodule Compos.Core.KeyDispatch do
  @moduledoc """
  Key routing. Runs in the *caller's* process (LiveView, test, RPC) — never
  inside Editor or Session — so command execution can freely call both.

  Policy here is minimal and mechanical: minibuffer input editing, prefix-key
  accumulation, self-insert fast path. What keys *mean* is Scheme's business
  (keymap contents + commands all come from editor.scm / init.scm).

  Key spec strings follow Emacs: `"a"`, `"C-x"`, `"M-x"`, `"C-M-f"`, `"RET"`,
  `"DEL"`, `"TAB"`, `"SPC"`, `"<left>"`.
  """

  alias Compos.Core.{Buffer, Editor, Frame, Session}

  @named ~w(RET DEL TAB SPC ESC <delete> <left> <right> <up> <down> <home> <end>)
  @prefix_commands ~w(universal-argument digit-argument negative-argument)

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
    snapshot = Editor.snapshot()
    %{minibuffer: mb, pending: pending, completion: completion} = snapshot
    transient = Map.get(snapshot, :transient)

    capture = Map.get(snapshot, :key_capture)

    cond do
      capture -> capture_key(key, pending, capture)
      mb -> minibuffer_key(key, mb, pending)
      completion -> completion_key(key, pending)
      transient -> transient_key(key, pending)
      true -> buffer_key(key, pending, Map.get(snapshot, :prefix_arg))
    end

    :ok
  end

  @doc """
  An input intent from the browser's text pipeline (`beforeinput`): TYPE is
  the inputType, FROM..TO the byte range it targets (-1 = at point), TEXT
  what it inserts. A collapsed intent at point is the key it stands for and
  takes the key path, so the minibuffer, the keymaps, and completion see it
  as a key. A ranged intent is Scheme policy (`input-intent!`).
  """
  def handle_intent(type, from, to, text) when is_binary(type) and is_binary(text) do
    snapshot = Editor.snapshot()

    routed? =
      Map.get(snapshot, :minibuffer) != nil or Map.get(snapshot, :completion) != nil or
        Map.get(snapshot, :transient) != nil or Map.get(snapshot, :key_capture) != nil

    buffer = Editor.current_buffer()
    point = if Buffer.exists?(buffer), do: Buffer.point(buffer), else: 0
    # a collapsed intent acts at point, whatever byte the client named: the
    # DOM caret lags the server by one patch, and typing goes where point is
    at_point? = from == to

    cond do
      at_point? and intent_key(type, text) != nil ->
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
        Editor.set_echo("input-intent: #{inspect(other)}")
    end
  end

  # --- completion popup routing ----------------------------------------------
  # What the popup's keys MEAN is Scheme's business (dup #22): the
  # " *completion*" keymap in editor.scm binds move/accept/quit, rebindable
  # like any map. Only the mechanics stay here: an unbound printable keeps
  # narrowing, SPC and everything else dismiss and act normally.

  @completion_map " *completion*"

  defp completion_key(key, pending) do
    case Editor.lookup_keymap(@completion_map, [key]) do
      {:command, name} ->
        run(name)

      _ ->
        cond do
          key == "DEL" ->
            # narrow in place: the popup's query shrinks with the buffer text
            Buffer.delete_char(Editor.current_buffer(), -1)
            requery_completion()

          key == "SPC" ->
            Editor.completion_dismiss()
            self_insert(" ")

          printable?(key) ->
            self_insert(key)
            requery_completion()

          true ->
            # any other key dismisses and acts normally
            Editor.completion_dismiss()
            buffer_key(key, pending)
        end
    end
  end

  # --- one-shot key capture --------------------------------------------------
  # Scheme arms the capture (describe-key does). The next COMPLETE key
  # sequence runs the armed command instead of its own binding, and that
  # command reads the sequence back with (last-keys). A prefix accumulates
  # here the way it does everywhere else, so the capture reads "C-x C-f"
  # as one sequence.

  defp capture_key(key, pending, command) do
    Editor.user_acted()
    seq = pending ++ [key]

    case lookup_esc_meta(seq) do
      :prefix ->
        Editor.set_pending(seq)
        Editor.set_echo(Enum.join(seq, " ") <> "-")

      _ ->
        Editor.set_pending([])
        Editor.set_key_capture(nil)
        Editor.set_last_keys(seq)
        Editor.set_echo("")
        run(command)
    end
  end

  # --- minibuffer routing ----------------------------------------------------
  # The minibuffer is a buffer: keys go through the normal keymap machinery.
  # Its local map (bound in editor.scm) shadows the global one for RET/C-g/
  # TAB/C-n/C-p/DEL; everything else — motion, kill/yank, undo, M-DEL — is
  # just the global editing commands acting on the *minibuf* buffer, which
  # Editor.current_buffer/lookup_key route to while a prompt is active.

  defp minibuffer_key(key, mb, pending) do
    # unresolved chords stay silent here: the echo area is the prompt
    resolve_and_run(key, pending, fn _seq -> :ok end)

    # any edit to the backing buffer fires the prompt's on_change handler
    # (isearch, find-file filtering); confirm/cancel closed the prompt, so
    # sync is a no-op there
    case Editor.minibuffer_sync_input() do
      {:changed, input} ->
        case mb do
          %{on_change: oc} when oc not in [nil, false] -> Session.apply_callback(oc, [input])
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  # --- buffer routing --------------------------------------------------------

  # Scheme owns the active Transient keymap and resolves the sequence. The
  # core only maintains the pending chord and invokes the returned command.
  defp transient_key(key, pending) do
    Editor.user_acted()
    Editor.set_echo("")
    seq = pending ++ [key]

    case Session.call_named("transient-dispatch-key", [seq]) do
      {:ok, ["command", name]} ->
        Editor.set_pending([])
        run(name)

      {:ok, ["prefix"]} ->
        Editor.set_pending(seq)
        Editor.set_echo(Enum.join(seq, " ") <> "-")

      _ ->
        Editor.set_pending([])
        Editor.set_echo(Enum.join(seq, " ") <> " is not a transient suffix")
    end
  end

  defp buffer_key(key, pending), do: buffer_key(key, pending, Editor.prefix_arg())

  defp buffer_key(key, pending, prefix_arg) do
    # a key ends any manual-scroll override: the view follows point again
    Editor.user_acted()
    Editor.set_echo("")

    if prefix_arg != nil and pending == [] and argument_key?(key) do
      Editor.set_last_keys([key])
      run(if(key == "-", do: "negative-argument", else: "digit-argument"))
    else
      resolve_and_run(
        key,
        pending,
        fn seq ->
          Editor.set_prefix_arg(nil)
          Editor.set_echo(Enum.join(seq, " ") <> " is undefined")
        end,
        prefix_arg
      )
    end
  end

  # THE lookup ladder (dup #21) — every surface resolves a key the same
  # way: append it to the pending prefix, look the sequence up, and fall
  # through. A command runs; a prefix accumulates and echoes; anything
  # else clears the prefix, self-inserts a printable, and otherwise defers
  # to UNDEFINED — the one point where the surfaces differ.
  defp resolve_and_run(key, pending, undefined, prefix_arg \\ nil) do
    seq = pending ++ [key]

    case lookup_esc_meta(seq) do
      {:command, name} ->
        Editor.set_pending([])
        # the sequence that ran the command: one command bound to many
        # keys (the switcher's type-to-narrow) reads it back
        Editor.set_last_keys(seq)
        # the prefix echo ("C-c-") must not outlive the sequence: the
        # command can close the prompt, and the echo bar comes back into
        # view still showing it
        if pending != [], do: Editor.set_echo("")
        run(name)

      :prefix ->
        Editor.set_pending(seq)
        Editor.set_echo(Enum.join(seq, " ") <> "-")

      :none ->
        Editor.set_pending([])

        cond do
          pending == [] and key == "SPC" -> self_insert(" ", prefix_arg)
          pending == [] and printable?(key) -> self_insert(key, prefix_arg)
          true -> undefined.(seq)
        end
    end
  end

  # ESC is Meta when nothing binds it directly (Emacs: ESC x runs M-x,
  # ESC C-f runs C-M-f). A map that binds ESC itself — evil, the
  # completion popup — wins, because the plain sequence resolves first.
  defp lookup_esc_meta(seq) do
    case Editor.lookup_key(seq) do
      :none ->
        case Enum.reverse(seq) do
          ["ESC" | _] ->
            :prefix

          [last, "ESC" | rev] ->
            Editor.lookup_key(Enum.reverse(rev) ++ [add_meta(last)])

          _ ->
            :none
        end

      hit ->
        hit
    end
  end

  # modifier order in a key spec: s- C- M- BASE (the client builds them so)
  defp add_meta(key) do
    {sup, rest} = split_mod(key, "s-")
    {ctl, rest} = split_mod(rest, "C-")
    if String.starts_with?(rest, "M-"), do: key, else: sup <> ctl <> "M-" <> rest
  end

  defp split_mod(key, mod) do
    if String.starts_with?(key, mod),
      do: {mod, binary_part(key, byte_size(mod), byte_size(key) - byte_size(mod))},
      else: {"", key}
  end

  # text typed since the popup opened is the popup's query (orderless narrowing)
  defp requery_completion do
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

  defp self_insert(text, prefix_arg \\ nil) do
    count = prefix_numeric_value(prefix_arg)
    inserted = if count > 0, do: String.duplicate(text, count), else: ""

    # A printable key replaces an active region in Emacs. The fast path used
    # to insert directly into the rope, which made mirrored selections from a
    # Markdown preview behave differently from delete commands.
    case Session.call_named("region-text", []) do
      {:ok, region} when is_binary(region) and byte_size(region) > 0 ->
        Session.run_command("delete-backward-char")

      _ ->
        :ok
    end

    case Buffer.insert(Editor.current_buffer(), inserted) do
      :ok ->
        Editor.finish_command("self-insert-command", false)

      {:error, :read_only} ->
        Editor.finish_command("self-insert-command", false)
        Editor.set_echo("Buffer is read-only")
    end
  end

  defp run(name) do
    # Emacs: any command except undo breaks the undo chain — a subsequent
    # undo then reverses the undos, which is how redo works. Commands that
    # manage their own boundaries (evil's dispatchers) register as exempt.
    unless Editor.undo_exempt?(name) do
      buffer = Editor.current_buffer()
      if Buffer.exists?(buffer), do: Buffer.break_undo_chain(buffer)
    end

    case Session.run_command(name) do
      :ok ->
        keep_prefix = name in @prefix_commands
        Editor.finish_command(name, keep_prefix)
        if keep_prefix, do: show_prefix_arg()

      {:error, msg} ->
        Editor.finish_command(name, false)
        Editor.set_echo("#{name}: #{msg}")
    end
  end

  defp argument_key?(key), do: key in ~w(0 1 2 3 4 5 6 7 8 9 -)

  defp prefix_numeric_value(nil), do: 1
  defp prefix_numeric_value([n]) when is_integer(n), do: n
  defp prefix_numeric_value(n) when is_integer(n), do: n
  defp prefix_numeric_value({:sym, "-"}), do: -1
  defp prefix_numeric_value(_), do: 1

  defp show_prefix_arg do
    text =
      case Editor.prefix_arg() do
        [n] -> "C-u #{n}"
        n when is_integer(n) -> Integer.to_string(n)
        {:sym, "-"} -> "-"
        _ -> "C-u"
      end

    Editor.set_echo(text)
  end

  defp printable?(key) do
    key not in @named and not String.starts_with?(key, "C-") and
      not String.starts_with?(key, "M-") and String.length(key) == 1
  end
end
