defmodule Compos.Scheme do
  @moduledoc """
  The compos.el extension language: a small Scheme whose values are BEAM terms.

  An interpreter is a small Elixir struct — a handle on a shared ETS
  environment store plus the global frame ref. Hold it in any process;
  many processes can evaluate against the same interpreter at once, and
  the BEAM preempts them, so one slow eval never blocks another. Host applications extend it by injecting
  primitives (plain Elixir funs) at construction or later.

      interp = Compos.Scheme.new(primitives: %{"shout" => fn [s] -> String.upcase(s) end})
      {:ok, val, interp} = Compos.Scheme.eval_string(interp, "(shout \\"hey\\")")
  """

  alias Compos.Scheme.{Builtins, Env, Eval, Printer, Reader}

  defstruct [:store, :global]

  # map, filter, remove, for-each, fold and assoc are builtins: an
  # interpreted loop paid one frame and a dozen evals per element
  @prelude """
  (define (cadr l) (car (cdr l)))
  (define (cddr l) (cdr (cdr l)))
  (define (caddr l) (car (cdr (cdr l))))
  (define (split-lines s) (string-split s "\\n"))
  (define (assq key lst) (assoc key lst))
  (define (list-ref lst i) (if (= i 0) (car lst) (list-ref (cdr lst) (- i 1))))
  (define (iota n)
    (let loop ((i 0) (acc '()))
      (if (= i n) (reverse acc) (loop (+ i 1) (cons i acc)))))
  """

  @doc "Create an interpreter. Options: `:primitives` — map of name -> fun/1 or fun/2."
  def new(opts \\ []) do
    builtins =
      Builtins.all()
      |> Map.merge(Keyword.get(opts, :primitives, %{}))
      |> Map.new(fn {name, fun} -> {name, {:builtin, name, fun}} end)

    {global, store} = Env.new_frame(Env.new(), nil, builtins)
    interp = %__MODULE__{store: store, global: global}
    {:ok, _, interp} = eval_string(interp, @prelude)
    # the global frame stays in the local tier: the host loads its whole
    # stdlib at old single-process speed, then publishes once (flush/1)
    interp
  end

  @doc "Register additional primitives on an existing interpreter."
  def register(%__MODULE__{} = interp, primitives) do
    store =
      Enum.reduce(primitives, interp.store, fn {name, fun}, store ->
        Env.define(store, interp.global, name, {:builtin, name, fun})
      end)

    %{interp | store: store}
  end

  @doc """
  Re-bind every host primitive in the global frame, after a code reload.

  A primitive is an anonymous fun the host captured when it built this
  interpreter. Recompiling the module that defined the fun purges the old
  version, and calling the captured fun then raises "function ... is
  invalid, likely because it points to an old version of the code". This
  rebinds each name to a fun from the module version now loaded. EXTRA is
  the host's own primitive map, merged over the builtins exactly as `new/1`
  merges it.

  The global frame lives in the shared tier after boot, so the new binding
  is visible to every lane at once.
  """
  def rebind_primitives(%__MODULE__{} = interp, extra \\ %{}) do
    fresh = Map.merge(Builtins.all(), extra)

    # The caller is a host process outside `exec`, so its read cache is a
    # leftover from whatever it evaluated last. The walk below reads every
    # global name and writes back what it reads; a stale cached value would
    # get written into the shared tier and undo a later definition. Read
    # from ETS.
    Env.forget_cached_reads()

    # Rebind by the primitive's OWN name, never by the variable's. A host
    # stdlib routinely wraps a primitive — `(define raw-buffer-create
    # buffer-create)` then `(define (buffer-create name) ...)` — so writing
    # `fresh` straight into the global frame would put the primitive back
    # over the wrapper and undo the stdlib. Instead: walk the frame, and
    # where a variable still holds a builtin, swap that builtin's fun for
    # the one the loaded module has now. The alias keeps its alias; the
    # wrapper keeps its wrapper; every dead fun goes.
    store =
      Enum.reduce(Env.frame_names(interp.store, interp.global), interp.store, fn name, store ->
        case Env.fetch(store, interp.global, name) do
          {:ok, {:builtin, primitive, _old}} ->
            case Map.fetch(fresh, primitive) do
              {:ok, fun} -> Env.define(store, interp.global, name, {:builtin, primitive, fun})
              :error -> store
            end

          _ ->
            store
        end
      end)

    # A primitive this version ADDS, which no name holds yet. Anything the
    # frame already binds is left alone: a host that redefined a primitive
    # in Scheme and kept no alias must keep its redefinition.
    register(%{interp | store: store}, Map.drop(fresh, Env.frame_names(store, interp.global)))
  end

  @doc "Snapshot the shared Scheme world for an isolated actor."
  def snapshot(%__MODULE__{store: store, global: global}) do
    {global, Env.export_shared(store)}
  end

  @doc "Create an isolated interpreter from snapshot/1 data."
  def from_snapshot({global, rows}, access \\ :private) do
    %__MODULE__{store: Env.import_shared(rows, access), global: global}
  end

  @doc """
  Evaluate all forms in a string. Returns `{:ok, last_value, interp}` or
  `{:error, message}`. Definitions made before the failing form persist —
  the store is shared and mutable, as in Emacs.
  """
  def eval_string(%__MODULE__{} = interp, src) do
    eval_forms(interp, Reader.read_all(src))
  rescue
    # eval_forms rescues what evaluation raises, but the read runs before
    # it. Unbalanced text is the ordinary way a caller gets this wrong -
    # a half-typed form in the minibuffer, a truncated file - and it must
    # answer like every other error, not raise through the caller.
    e in Reader.Error -> {:error, Exception.message(e)}
  end

  @doc "Evaluate already parsed top-level forms."
  def eval_forms(%__MODULE__{} = interp, forms) when is_list(forms) do
    {val, store} =
      Enum.reduce(forms, {:void, interp.store}, fn form, {_val, store} ->
        Eval.eval(form, interp.global, store)
      end)

    {:ok, val, %{interp | store: store}}
  rescue
    e in [Reader.Error, Eval.Error, Env.UnboundError] ->
      {:error, Exception.message(e)}

    e in [FunctionClauseError, MatchError, ArithmeticError, CaseClauseError] ->
      {:error, "bad arguments: #{Exception.message(e)}"}
  end

  @doc "Call a Scheme value (closure/builtin) from Elixir."
  def call(%__MODULE__{} = interp, f, args) do
    {val, store} = Eval.apply_fn(f, args, interp.store)
    {:ok, val, %{interp | store: store}}
  rescue
    e in [Eval.Error, Env.UnboundError] ->
      {:error, Exception.message(e)}

    e in [FunctionClauseError, MatchError, ArithmeticError, CaseClauseError, ArgumentError] ->
      {:error, "bad arguments: #{Exception.message(e)}"}
  end

  @doc """
  Garbage-collect environment frames. `roots` is a list of arbitrary terms;
  closures found anywhere inside them (plus the global frame) keep their
  captured environments alive. Everything else is dropped.
  """
  defdelegate gc(interp, roots), to: Compos.Scheme.GC, as: :sweep

  @doc "The number of live environment frames in the store."
  def frame_count(%__MODULE__{store: store}), do: Env.frame_count(store)

  @doc """
  Run FUN as one top-level eval. The run is registered in flight (no
  sweep runs under it), and on success the eval's local frames flush to
  the shared tier — still inside the in-flight section, so escaped
  closures are resolvable from any process before a sweep can run. FUN
  gets the interpreter and returns `{:ok, value, interp}` or
  `{:error, message}`; an error drops the eval's local frames.

  Every entry point that evaluates Scheme must go through this.
  """
  def exec(%__MODULE__{store: store} = interp, fun) do
    Env.with_eval(store, fn ->
      case fun.(interp) do
        # Primitive arguments and shared writes promote before exposure.
        # The exit flush keeps result closures and drops dead call frames.
        {:ok, val, %__MODULE__{} = interp2} -> {:ok, val, flush(interp2, [val])}
        other -> other
      end
    end)
  end

  @doc "Publish the whole local frame tier to the shared table (boot)."
  def flush(%__MODULE__{store: store} = interp), do: %{interp | store: Env.flush(store)}

  @doc "Publish only the local frames reachable from ROOTS or from the global frame."
  def flush(%__MODULE__{store: store, global: global} = interp, roots),
    do: %{interp | store: Env.flush(store, roots, [global])}

  defdelegate print(value), to: Printer
end
