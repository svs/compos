defmodule Aimax.Scheme.Eval do
  @moduledoc """
  Tail-recursive evaluator. Runs entirely on BEAM terms; proper tail calls
  come from the BEAM itself (all tail positions are direct recursive calls).

  Closures: `{:closure, {required, optional, rest}, body, env_ref}` — param
  lists use elisp-style `&optional` / `&rest` markers (flat, no dotted pairs);
  missing optionals bind `#f`, `&rest` binds a (possibly empty) list.
  Builtins: `{:builtin, name, fun}` where fun is `(args -> value)` or
            `(args, store -> {value, store})` for store-aware primitives.
  """

  alias Aimax.Scheme.Env

  defmodule Error do
    defexception [:message]
  end

  @doc "Evaluate one form. Returns {value, store}."
  def eval(expr, env, store)

  def eval({:sym, name}, env, store), do: {Env.lookup(store, env, name), store}

  def eval(expr, _env, store)
      when is_number(expr) or is_binary(expr) or is_boolean(expr),
      do: {expr, store}

  def eval([{:sym, "quote"}, form], _env, store), do: {form, store}

  def eval([{:sym, "if"}, c, t], env, store), do: eval([{:sym, "if"}, c, t, :void], env, store)

  def eval([{:sym, "if"}, c, t, e], env, store) do
    {cond_val, store} = eval_arg(c, env, store)

    cond do
      cond_val == false -> if e == :void, do: {:void, store}, else: eval(e, env, store)
      true -> eval(t, env, store)
    end
  end

  def eval([{:sym, "define"}, {:sym, name}, value_form], env, store) do
    {val, store} = eval_arg(value_form, env, store)
    {:void, Env.define(store, env, name, val)}
  end

  # (define (f a b) body...) sugar
  def eval([{:sym, "define"}, [{:sym, name} | params] | body], env, store) do
    eval([{:sym, "define"}, {:sym, name}, [{:sym, "lambda"}, params | body]], env, store)
  end

  def eval([{:sym, "lambda"}, params | body], env, store) do
    {{:closure, param_names!(params), body, env}, store}
  end

  def eval([{:sym, "set!"}, {:sym, name}, value_form], env, store) do
    {val, store} = eval_arg(value_form, env, store)
    {:void, Env.set!(store, env, name, val)}
  end

  def eval([{:sym, "begin"} | body], env, store), do: eval_seq(body, env, store)

  # named let: (let loop ((i 0)) ... (loop (+ i 1))) — tail-recursive iteration
  def eval([{:sym, "let"}, {:sym, name}, bindings | body], env, store) do
    {names, forms} =
      bindings
      |> Enum.map(fn [{:sym, n}, form] -> {n, form} end)
      |> Enum.unzip()

    {vals, store} = eval_args(forms, env, store, [])
    {frame, store} = Env.new_frame(store, env)
    closure = {:closure, {names, [], nil}, body, frame}
    store = Env.define(store, frame, name, closure)
    apply_fn(closure, vals, store)
  end

  def eval([{:sym, "let"}, bindings | body], env, store) do
    {vars, store} =
      Enum.reduce(bindings, {%{}, store}, fn [{:sym, name}, form], {vars, store} ->
        {val, store} = eval_arg(form, env, store)
        {Map.put(vars, name, val), store}
      end)

    {frame, store} = Env.new_frame(store, env, vars)
    eval_seq(body, frame, store)
  end

  def eval([{:sym, "and"} | args], env, store), do: eval_and(args, env, store)
  def eval([{:sym, "or"} | args], env, store), do: eval_or(args, env, store)

  def eval([{:sym, "cond"} | clauses], env, store), do: eval_cond(clauses, env, store)

  def eval([{:sym, "when"}, test | body], env, store) do
    {val, store} = eval_arg(test, env, store)
    if val == false, do: {:void, store}, else: eval_seq(body, env, store)
  end

  def eval([{:sym, "unless"}, test | body], env, store) do
    {val, store} = eval_arg(test, env, store)
    if val == false, do: eval_seq(body, env, store), else: {:void, store}
  end

  # let*: each binding sees the previous ones — a fresh frame per binding
  def eval([{:sym, "let*"}, bindings | body], env, store) do
    {frame, store} =
      Enum.reduce(bindings, {env, store}, fn [{:sym, name}, form], {env, store} ->
        {val, store} = eval_arg(form, env, store)
        Env.new_frame(store, env, %{name => val})
      end)

    eval_seq(body, frame, store)
  end

  # application
  def eval([op | arg_forms], env, store) do
    {f, store} = eval_arg(op, env, store)
    {args, store} = eval_args(arg_forms, env, store, [])
    apply_fn(f, args, store)
  end

  def eval(other, _env, _store) do
    raise Error, message: "cannot evaluate: #{inspect(other)}"
  end

  @doc "Apply a Scheme callable to already-evaluated args."
  def apply_fn({:closure, {req, opt, rest}, body, closure_env}, args, store) do
    vars = bind_params!(req, opt, rest, args)
    {frame, store} = Env.new_frame(store, closure_env, vars)
    eval_seq(body, frame, store)
  end

  def apply_fn({:builtin, _name, fun}, args, store) when is_function(fun, 1),
    do: {fun.(args), store}

  def apply_fn({:builtin, _name, fun}, args, store) when is_function(fun, 2),
    do: fun.(args, store)

  def apply_fn(other, _args, _store) do
    raise Error, message: "not a function: #{inspect(other)}"
  end

  # --- helpers ---------------------------------------------------------------

  # non-tail evaluation of a subexpression
  defp eval_arg(form, env, store), do: eval(form, env, store)

  defp eval_args([], _env, store, acc), do: {Enum.reverse(acc), store}

  defp eval_args([form | rest], env, store, acc) do
    {val, store} = eval_arg(form, env, store)
    eval_args(rest, env, store, [val | acc])
  end

  # last form is in tail position
  defp eval_seq([form], env, store), do: eval(form, env, store)

  defp eval_seq([form | rest], env, store) do
    {_val, store} = eval_arg(form, env, store)
    eval_seq(rest, env, store)
  end

  defp eval_seq([], _env, store), do: {:void, store}

  defp eval_cond([], _env, store), do: {:void, store}

  defp eval_cond([[{:sym, "else"} | body] | _rest], env, store), do: eval_seq(body, env, store)

  defp eval_cond([[test | body] | rest], env, store) do
    {val, store} = eval_arg(test, env, store)

    cond do
      val == false -> eval_cond(rest, env, store)
      body == [] -> {val, store}
      true -> eval_seq(body, env, store)
    end
  end

  defp eval_and([], _env, store), do: {true, store}
  defp eval_and([last], env, store), do: eval(last, env, store)

  defp eval_and([form | rest], env, store) do
    {val, store} = eval_arg(form, env, store)
    if val == false, do: {false, store}, else: eval_and(rest, env, store)
  end

  defp eval_or([], _env, store), do: {false, store}
  defp eval_or([last], env, store), do: eval(last, env, store)

  defp eval_or([form | rest], env, store) do
    {val, store} = eval_arg(form, env, store)
    if val == false, do: eval_or(rest, env, store), else: {val, store}
  end

  defp param_names!(params) do
    params
    |> Enum.map(fn
      {:sym, name} -> name
      other -> raise Error, message: "bad parameter: #{inspect(other)}"
    end)
    |> parse_params!([], :req)
  end

  # flat elisp-style param list -> {required, optional, rest-name-or-nil}
  defp parse_params!([], req, :req), do: {Enum.reverse(req), [], nil}

  defp parse_params!(["&optional" | more], req, :req) do
    {opt, rest} = parse_optionals!(more, [])
    {Enum.reverse(req), opt, rest}
  end

  defp parse_params!(["&rest" | more], req, :req),
    do: {Enum.reverse(req), [], rest_name!(more)}

  defp parse_params!([name | more], req, :req), do: parse_params!(more, [name | req], :req)

  defp parse_optionals!([], opt), do: {Enum.reverse(opt), nil}
  defp parse_optionals!(["&rest" | more], opt), do: {Enum.reverse(opt), rest_name!(more)}

  defp parse_optionals!(["&optional" | _], _),
    do: raise(Error, message: "&optional appears twice in parameter list")

  defp parse_optionals!([name | more], opt), do: parse_optionals!(more, [name | opt])

  defp rest_name!([name]) when name not in ["&optional", "&rest"], do: name
  defp rest_name!(other), do: raise(Error, message: "&rest takes exactly one name, got: #{inspect(other)}")

  defp bind_params!(req, opt, rest, args) do
    nreq = length(req)
    nargs = length(args)
    max = if rest, do: nil, else: nreq + length(opt)

    cond do
      nargs < nreq and opt == [] and rest == nil ->
        raise Error, message: "arity mismatch: expected #{nreq}, got #{nargs}"

      nargs < nreq ->
        raise Error, message: "arity mismatch: expected at least #{nreq}, got #{nargs}"

      max != nil and nargs > max ->
        expected = if opt == [], do: "#{nreq}", else: "at most #{max}"
        raise Error, message: "arity mismatch: expected #{expected}, got #{nargs}"

      true ->
        {req_args, more} = Enum.split(args, nreq)
        {opt_args, rest_args} = Enum.split(more, length(opt))
        opt_vals = opt_args ++ List.duplicate(false, length(opt) - length(opt_args))

        vars = Map.new(Enum.zip(req, req_args) ++ Enum.zip(opt, opt_vals))
        if rest, do: Map.put(vars, rest, rest_args), else: vars
    end
  end
end
