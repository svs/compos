defmodule Aimax.Scheme do
  @moduledoc """
  The ai-max.el extension language: a small Scheme whose values are BEAM terms.

  An interpreter is an immutable Elixir struct — hold it in any process,
  thread it through calls. Host applications extend it by injecting
  primitives (plain Elixir funs) at construction or later.

      interp = Aimax.Scheme.new(primitives: %{"shout" => fn [s] -> String.upcase(s) end})
      {:ok, val, interp} = Aimax.Scheme.eval_string(interp, "(shout \\"hey\\")")
  """

  alias Aimax.Scheme.{Builtins, Env, Eval, Printer, Reader}

  defstruct [:store, :global]

  @prelude """
  (define (map f lst)
    (if (null? lst) '() (cons (f (car lst)) (map f (cdr lst)))))
  (define (filter pred lst)
    (if (null? lst) '()
        (if (pred (car lst))
            (cons (car lst) (filter pred (cdr lst)))
            (filter pred (cdr lst)))))
  (define (for-each f lst)
    (if (null? lst) #t (begin (f (car lst)) (for-each f (cdr lst)))))
  (define (fold f acc lst)
    (if (null? lst) acc (fold f (f acc (car lst)) (cdr lst))))
  (define (assoc key lst)
    (if (null? lst) #f
        (if (equal? key (car (car lst))) (car lst) (assoc key (cdr lst)))))
  (define (cadr l) (car (cdr l)))
  (define (caddr l) (car (cdr (cdr l))))
  (define (split-lines s) (string-split s "\\n"))
  (define (assq key lst) (assoc key lst))
  (define (remove pred lst) (filter (lambda (x) (not (pred x))) lst))
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
  Evaluate all forms in a string. Returns `{:ok, last_value, interp}` or
  `{:error, message}` (interpreter unchanged on error).
  """
  def eval_string(%__MODULE__{} = interp, src) do
    forms = Reader.read_all(src)

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

  defdelegate print(value), to: Printer
end
