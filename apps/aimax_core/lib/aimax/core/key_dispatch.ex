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
    %{minibuffer: mb, pending: pending, completion: completion} = Editor.snapshot()

    cond do
      mb -> minibuffer_key(key, mb)
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
    # resolve the selection when the user arrowed onto it, or when the filter
    # narrowed to exactly one candidate (type "html", RET — no arrowing);
    # otherwise the typed input wins, so new files can still be created
    if (mb[:sel_touched] || mb[:total] == 1) && mb[:selected] do
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

  # in a path prompt, DEL at a directory boundary kills the whole
  # component ("~/src/ai-max.el/" -> "~/src/"); mid-name it's one char
  defp minibuffer_key("DEL", %{on_complete: oc, input: input} = mb)
       when oc not in [nil, false] do
    trimmed = String.replace(input, ~r{[^/]+/$}, "")

    if trimmed != input,
      do: set_input(mb, trimmed),
      else: set_input(mb, String.slice(input, 0..-2//1))
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
    # a key ends any manual-scroll override: the view follows point again
    Editor.user_acted()
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
