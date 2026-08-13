defmodule Aimax.Core.KeyDispatch do
  @moduledoc """
  Key routing. Runs in the *caller's* process (LiveView, test, RPC) — never
  inside Editor or Session — so command execution can freely call both.

  Policy here is minimal and mechanical: minibuffer input editing, prefix-key
  accumulation, self-insert fast path. What keys *mean* is Scheme's business
  (keymap contents + commands all come from editor.scm / init.scm).

  Key spec strings follow Emacs: `"a"`, `"C-x"`, `"M-x"`, `"C-M-f"`, `"RET"`,
  `"DEL"`, `"TAB"`, `"SPC"`, `"<left>"`.
  """

  alias Aimax.Core.{Buffer, Editor, Frame, Session}

  @named ~w(RET DEL TAB SPC ESC <left> <right> <up> <down> <home> <end>)

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
    %{minibuffer: mb, pending: pending, completion: completion} = Editor.snapshot()

    cond do
      mb -> minibuffer_key(key, mb, pending)
      completion -> completion_key(key, pending)
      true -> buffer_key(key, pending)
    end

    :ok
  end

  # --- completion popup routing ----------------------------------------------

  defp completion_key(key, pending) do
    cond do
      key in ["C-n", "<down>"] ->
        Editor.completion_move(1)

      key in ["C-p", "<up>"] ->
        Editor.completion_move(-1)

      key in ["RET", "TAB"] ->
        case Editor.completion_accept() do
          {start, label} ->
            buf = Editor.current_buffer()
            point = Buffer.point(buf)
            if point > start, do: Buffer.delete_range(buf, start, point - start)
            Buffer.insert(buf, label)

          nil ->
            :ok
        end

      key in ["C-g", "ESC"] ->
        Editor.completion_dismiss()
        Editor.set_echo("")

      key == "DEL" ->
        # narrow in place: the popup's own query shrinks with the buffer text
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

  defp buffer_key(key, pending) do
    # a key ends any manual-scroll override: the view follows point again
    Editor.user_acted()
    Editor.set_echo("")

    resolve_and_run(key, pending, fn seq ->
      Editor.set_echo(Enum.join(seq, " ") <> " is undefined")
    end)
  end

  # THE lookup ladder (dup #21) — every surface resolves a key the same
  # way: append it to the pending prefix, look the sequence up, and fall
  # through. A command runs; a prefix accumulates and echoes; anything
  # else clears the prefix, self-inserts a printable, and otherwise defers
  # to UNDEFINED — the one point where the surfaces differ.
  defp resolve_and_run(key, pending, undefined) do
    seq = pending ++ [key]

    case Editor.lookup_key(seq) do
      {:command, name} ->
        Editor.set_pending([])
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
          pending == [] and key == "SPC" -> self_insert(" ")
          pending == [] and printable?(key) -> self_insert(key)
          true -> undefined.(seq)
        end
    end
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

  defp self_insert(text) do
    case Buffer.insert(Editor.current_buffer(), text) do
      :ok -> Editor.set_last_command("self-insert-command")
      {:error, :read_only} -> Editor.set_echo("Buffer is read-only")
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
      :ok -> Editor.set_last_command(name)
      {:error, msg} -> Editor.set_echo("#{name}: #{msg}")
    end
  end

  defp printable?(key) do
    key not in @named and not String.starts_with?(key, "C-") and
      not String.starts_with?(key, "M-") and String.length(key) == 1
  end
end
