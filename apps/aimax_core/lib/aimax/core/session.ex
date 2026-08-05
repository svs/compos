defmodule Aimax.Core.Session do
  @moduledoc """
  An editor session: the process that owns the Scheme interpreter wired to the
  editor primitives. User/agent Scheme executes here — `M-:`, eval-region,
  RPC `eval`, init.scm, and every named command (they're all Scheme closures).

  Commands live in a public ETS table `{name, closure}` — registered by
  `(define-command ...)`, executed via `run_command/1` (from KeyDispatch) or
  `(run-command ...)` (from Scheme, e.g. M-x's confirm callback).

  The echo area is a view: `(message ...)` appends to `*messages*` and sets
  the transient echo. One global session for now; per-client later.
  """

  use GenServer

  require Logger

  alias Aimax.Core.{Buffer, Editor}
  alias Aimax.Scheme

  @messages "*messages*"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Evaluate Scheme source. Returns {:ok, printed_value} | {:error, msg}."
  def eval(src), do: GenServer.call(__MODULE__, {:eval, src}, 30_000)

  @doc "Run a named command (Scheme closure from the commands table)."
  def run_command(name), do: GenServer.call(__MODULE__, {:run_command, name}, 30_000)

  @doc "Apply a Scheme closure (e.g. a minibuffer confirm callback)."
  def apply_callback(closure, args),
    do: GenServer.call(__MODULE__, {:apply, closure, args}, 30_000)

  @doc "Apply a Scheme closure and return its value (e.g. a completion fn)."
  def call_fn(closure, args),
    do: GenServer.call(__MODULE__, {:call_fn, closure, args}, 30_000)

  def eval_region(buffer, start_pos, end_pos) do
    src = buffer |> Buffer.text() |> binary_part(start_pos, end_pos - start_pos)
    eval(src)
  end

  def eval_buffer(buffer), do: buffer |> Buffer.text() |> eval()

  def message(text) do
    Buffer.append(@messages, text <> "\n", source: :editor)
    Editor.set_echo(text)
    :ok
  end

  def command_names do
    Aimax.Core.SchemeAPI.commands_table()
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(Aimax.Core.SchemeAPI.commands_table(), [:named_table, :public, :set])
    {:ok, _} = Aimax.Core.create_buffer(@messages)

    interp = Scheme.new(primitives: Aimax.Core.SchemeAPI.primitives())
    interp = Scheme.register(interp, session_primitives(interp.global))
    interp = load_stdlib!(interp)

    {:ok, %{interp: interp}}
  end

  @impl true
  def handle_call({:eval, src}, _from, state) do
    case Scheme.eval_string(state.interp, src) do
      {:ok, val, interp} -> {:reply, {:ok, Scheme.print(val)}, %{state | interp: interp}}
      {:error, msg} -> {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:run_command, name}, _from, state) do
    case :ets.lookup(Aimax.Core.SchemeAPI.commands_table(), name) do
      [] ->
        {:reply, {:error, "undefined command"}, state}

      [{^name, closure}] ->
        case Scheme.call(state.interp, closure, []) do
          {:ok, _val, interp} -> {:reply, :ok, %{state | interp: interp}}
          {:error, msg} -> {:reply, {:error, msg}, state}
        end
    end
  end

  def handle_call({:apply, closure, args}, _from, state) do
    case Scheme.call(state.interp, closure, args) do
      {:ok, _val, interp} -> {:reply, :ok, %{state | interp: interp}}
      {:error, msg} ->
        message("error: " <> msg)
        {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:call_fn, closure, args}, _from, state) do
    case Scheme.call(state.interp, closure, args) do
      {:ok, val, interp} -> {:reply, {:ok, val}, %{state | interp: interp}}
      {:error, msg} -> {:reply, {:error, msg}, state}
    end
  end

  defp load_stdlib!(interp) do
    interp =
      Enum.reduce(["editor.scm", "dired.scm", "themes.scm"], interp, fn file, interp ->
        path = Application.app_dir(:aimax_core, "priv/#{file}")

        case Scheme.eval_string(interp, File.read!(path)) do
          {:ok, _, interp} ->
            interp

          {:error, msg} ->
            # the stdlib must load — a broken stdlib is a broken editor
            raise "#{file} failed to load: #{msg}"
        end
      end)

    load_init(interp)
  end

  # user config: ~/.aimax/ai-config.scm then init.scm — errors log loudly
  # but never brick boot. (load "...") works from inside either.
  defp load_init(interp) do
    Enum.reduce(["ai-config.scm", "init.scm"], interp, fn file, interp ->
      path = Path.expand("~/.aimax/#{file}")

      with true <- File.exists?(path),
           {:ok, _, interp2} <- Scheme.eval_string(interp, File.read!(path)) do
        interp2
      else
        false ->
          interp

        {:error, msg} ->
          Logger.error("#{file} error: #{msg}")
          interp
      end
    end)
  end

  defp session_primitives(global) do
    eval_src = fn src, store ->
      Enum.reduce(Aimax.Scheme.Reader.read_all(src), {:void, store}, fn form, {_v, store} ->
        Aimax.Scheme.Eval.eval(form, global, store)
      end)
    end

    %{
      "message" => fn [text] ->
        message(to_string(text))
        :void
      end,
      "define-command" => fn [name, closure] ->
        :ets.insert(Aimax.Core.SchemeAPI.commands_table(), {command_name(name), closure})
        :void
      end,
      "command-names" => fn [] -> command_names() end,
      "run-command" => fn [name], store ->
        case :ets.lookup(Aimax.Core.SchemeAPI.commands_table(), command_name(name)) do
          [] -> raise Aimax.Scheme.Eval.Error, message: "undefined command: #{command_name(name)}"
          [{_, closure}] -> Aimax.Scheme.Eval.apply_fn(closure, [], store)
        end
      end,
      "llm" => fn [prompt, callback] ->
        Aimax.Core.LLM.complete(prompt, fn text -> apply_callback(callback, [text]) end)
        :void
      end,
      "set-llm-model!" => fn [m] ->
        Aimax.Core.LLM.set_model(m)
        :void
      end,
      "llm-model" => fn [] -> Aimax.Core.LLM.model() end,
      "eval-string" => fn [src], store -> eval_src.(src, store) end,
      # load-library: evaluate a Scheme file in the live session
      "load" => fn [path], store ->
        expanded = Path.expand(path)

        case File.read(expanded) do
          {:ok, src} ->
            eval_src.(src, store)

          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error, message: "cannot load #{expanded}: #{reason}"
        end
      end,
      "eval-region" => fn [buffer, s, e], store ->
        src = buffer |> Buffer.text() |> binary_part(s, e - s)
        eval_src.(src, store)
      end,
      "eval-buffer" => fn [buffer], store ->
        eval_src.(Buffer.text(buffer), store)
      end
    }
  end

  defp command_name({:sym, s}), do: s
  defp command_name(s) when is_binary(s), do: s
end
