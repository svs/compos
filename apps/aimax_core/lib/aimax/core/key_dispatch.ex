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

  alias Aimax.Core.{Buffer, Editor, Session}

  @named ~w(RET DEL TAB SPC ESC <left> <right> <up> <down> <home> <end>)

  def handle_key(key) do
    %{minibuffer: mb, pending: pending} = Editor.snapshot()

    if mb, do: minibuffer_key(key, mb), else: buffer_key(key, pending)
    :ok
  end

  # --- minibuffer routing ----------------------------------------------------

  defp minibuffer_key("RET", _mb) do
    case Editor.minibuffer_close() do
      %{on_confirm: oc} = mb when oc != nil and oc != false ->
        Session.apply_callback(oc, [confirm_value(mb)])

      _ ->
        :ok
    end
  end

  # on_complete prompts (find-file): the input is the path being built. If
  # the user explicitly arrowed onto a candidate, resolve it through the
  # completion closure first — "down, RET" must enter the highlighted entry.
  defp confirm_value(%{on_complete: oc} = mb) when oc not in [nil, false] do
    if mb[:sel_touched] && mb[:selected] do
      case Session.call_fn(oc, [mb.input, mb[:selected]]) do
        {:ok, [new_input, _cands]} when is_binary(new_input) -> new_input
        _ -> mb.input
      end
    else
      mb.input
    end
  end

  defp confirm_value(mb), do: mb[:selected] || mb.input

  defp minibuffer_key(key, _mb) when key in ["C-n", "<down>"],
    do: Editor.minibuffer_move_sel(1)

  defp minibuffer_key(key, _mb) when key in ["C-p", "<up>"],
    do: Editor.minibuffer_move_sel(-1)

  defp minibuffer_key("C-g", _mb) do
    case Editor.minibuffer_close() do
      %{on_cancel: oc} when oc != nil and oc != false -> Session.apply_callback(oc, [])
      _ -> :ok
    end

    Editor.set_echo("Quit")
  end

  defp minibuffer_key("DEL", mb),
    do: set_input(mb, String.slice(mb.input, 0..-2//1))

  defp minibuffer_key("TAB", %{on_complete: oc} = mb) when oc != nil and oc != false do
    # completion policy is a Scheme closure:
    #   (input selected-or-#f) -> (list new-input candidates)
    # an arrowed-onto candidate is inserted (and directories auto-descend)
    selected = (mb[:sel_touched] && Editor.minibuffer_selected()) || false

    case Session.call_fn(oc, [mb.input, selected]) do
      {:ok, [new_input, candidates]} when is_binary(new_input) and is_list(candidates) ->
        Editor.minibuffer_set_input(new_input)
        Editor.minibuffer_set_candidates(candidates)

      _ ->
        :ok
    end
  end

  # no completion fn: TAB completes the input to the selected candidate
  defp minibuffer_key("TAB", _mb) do
    case Editor.minibuffer_selected() do
      nil -> :ok
      label -> Editor.minibuffer_set_input(label)
    end
  end

  defp minibuffer_key("SPC", mb), do: set_input(mb, mb.input <> " ")

  defp minibuffer_key(key, mb) do
    if printable?(key), do: set_input(mb, mb.input <> key), else: :ok
  end

  # input edits fire the minibuffer's on_change handler (isearch et al.)
  defp set_input(mb, new_input) do
    Editor.minibuffer_set_input(new_input)

    case mb do
      %{on_change: oc} when oc != nil and oc != false ->
        Session.apply_callback(oc, [new_input])

      _ ->
        :ok
    end
  end

  # --- buffer routing --------------------------------------------------------

  defp buffer_key(key, pending) do
    Editor.set_echo("")
    seq = pending ++ [key]

    case Editor.lookup_key(seq) do
      {:command, name} ->
        Editor.set_pending([])
        run(name)

      :prefix ->
        Editor.set_pending(seq)
        Editor.set_echo(Enum.join(seq, " ") <> "-")

      :none ->
        Editor.set_pending([])

        cond do
          pending == [] and key == "SPC" -> self_insert(" ")
          pending == [] and printable?(key) -> self_insert(key)
          true -> Editor.set_echo(Enum.join(seq, " ") <> " is undefined")
        end
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
    # undo then reverses the undos, which is how redo works
    if name != "undo" do
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
