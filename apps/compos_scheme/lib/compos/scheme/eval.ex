defmodule Compos.Scheme.Eval do
  require Logger

  @moduledoc """
  Compiling evaluator. A form compiles once into tagged tuples, which `run`
  evaluates; proper tail calls come from the BEAM itself (all tail positions
  are direct recursive calls).

  Closures: `{:closure, {required, optional, rest}, {tag, compiled, source},
  env}` — the body keeps its source for `function-source`. TAG is
  `:lcode` when the body's locals need no store frame (see code/4), else
  `:code`; ENV is a frame ref, or `{:lex, vars, ref}` for a closure made
  inside a lexical body. Param
  lists use elisp-style `&optional` / `&rest` markers, or R7RS `(a . rest)`;
  missing optionals bind `#f`, `&rest` binds a (possibly empty) list.
  Builtins: `{:builtin, name, fun}` where fun is `(args -> value)` or
            `(args, store -> {value, store})` for store-aware primitives.
  """

  import Bitwise

  alias Compos.Scheme.Env

  defmodule Error do
    defexception [:message]
  end

  # --- runaway recursion ------------------------------------------------------
  # Emacs stops a function that calls itself with no base case through
  # `max-lisp-eval-depth`. Without a bound here, such a function grew the
  # heap until `max_heap_size` killed the process: seconds of work, several
  # hundred megabytes of RSS on a daemon meant to run for weeks, and an
  # error that named the heap instead of the recursion.
  #
  # The BEAM's own stack is the measure. One nested Scheme call costs six
  # words of it, and a TAIL call costs nothing: a 1,000,000-iteration tail
  # loop leaves the stack at 134 words, because every tail position in this
  # evaluator is a direct recursive call. So reading the process stack counts
  # real nesting, and never charges a loop for iterating.
  #
  # Reading it on every application would pay a BIF per call, so a counter in
  # the process dictionary samples: one read every 1024 applications bounds
  # the overshoot at 1024 frames and costs about 2% of an application.
  @words_per_frame 6
  @stack_floor_words 140
  @sample_mask 0x3FF
  @default_depth 100_000
  @applies :compos_scheme_applies

  @doc """
  The nesting a Scheme program may reach before `Error` stops it.

  `config :compos_scheme, max_recursion_depth: 0` turns the bound off.
  """
  def max_recursion_depth,
    do: Application.get_env(:compos_scheme, :max_recursion_depth, @default_depth)

  defp stack_limit_words do
    case max_recursion_depth() do
      depth when is_integer(depth) and depth > 0 ->
        @stack_floor_words + depth * @words_per_frame

      _ ->
        nil
    end
  end

  # Called before a closure body runs, from the one place nesting deepens.
  # It must stay a separate statement: the body's evaluation is a tail call,
  # and wrapping it would cost the evaluator its proper tail calls.
  defp count_nesting!(body) do
    n = Process.get(@applies, 0) + 1
    Process.put(@applies, n)

    if band(n, @sample_mask) == 0, do: check_nesting!(body)

    :ok
  end

  defp check_nesting!(body) do
    limit = stack_limit_words()
    {:stack_size, words} = Process.info(self(), :stack_size)

    if limit && words > limit do
      Process.put(@applies, 0)

      # Error, not a type of its own: every path that reports a Scheme error
      # already rescues it, so the echo area says this instead of the lane
      # reporting a dead job.
      raise Error,
        message:
          "recursion is too deep: more than #{max_recursion_depth()} nested calls in " <>
            source_hint(body) <>
            " — a tail call costs no nesting here, so this is a function that " <>
            "calls itself with no base case"
    end

    :ok
  end

  # The closure that recursed has no name of its own, so name it by the
  # first line of its body. That is what identifies it in a source file.
  defp source_hint([form | _]) do
    text = Compos.Scheme.Printer.print(form)

    if String.length(text) > 120, do: String.slice(text, 0, 120) <> "...", else: text
  end

  defp source_hint(_), do: "a closure with an empty body"

  @doc "Evaluate one form. Returns {value, store}."
  def eval(form, env, store), do: run(compile(form, :dyn), env, store)

  @doc "The source forms of a closure body."
  def source({:code, _compiled, source}), do: source
  def source({:lcode, _compiled, source}), do: source
  def source({:lcode, _compiled, source, _names}), do: source
  def source(body), do: body

  # --- compile ----------------------------------------------------------------
  # The walker this replaces matched each form against every special-form
  # head, by string, each time the form ran, so a loop body paid the match
  # on every step. Now a form compiles once, when it is evaluated at top
  # level or when the lambda around it compiles, and a closure keeps its
  # compiled body. The tuples are data, not funs: a hot reload of this
  # module leaves every closure in the store valid.
  #
  # The special forms are the walker's, shape for shape: a form whose shape
  # no special form takes is an application, as before. A form that a
  # special form refuses compiles to a :fail node that raises the error
  # when it runs, so a bad form in a branch never taken never raises.
  defp compile(form, sc \\ :dyn) do
    comp(form, sc)
  rescue
    e -> {:fail, e, __STACKTRACE__}
  end

  # SC is the scope a form compiles in: :dyn, where every name is looked up
  # through the store's frames, or a map of the names a lexical closure
  # binds (see code/2), where a name is a local or a free name at once.
  defp comp({:sym, _} = sym, :dyn), do: sym
  defp comp({:sym, name}, sc) when is_map_key(sc, name), do: {:lvar, :erlang.map_get(name, sc)}
  defp comp({:sym, name}, _sc), do: {:gvar, name}
  defp comp(x, _sc) when is_number(x) or is_binary(x) or is_boolean(x), do: x
  defp comp([{:sym, "quote"}, form], _sc), do: {:quote, form}
  defp comp([{:sym, "if"}, c, t], sc), do: {:if, compile(c, sc), compile(t, sc), {:quote, :void}}
  defp comp([{:sym, "if"}, c, t, e], sc), do: {:if, compile(c, sc), compile(t, sc), compile(e, sc)}
  defp comp([{:sym, "define"}, {:sym, name}, value], sc), do: {:define, name, compile(value, sc)}

  # (define (f a b) body...) sugar
  defp comp([{:sym, "define"}, [{:sym, name} | params] | body], sc),
    do: {:define, name, compile([{:sym, "lambda"}, params | body], sc)}

  defp comp([{:sym, "lambda"}, params | body], sc) do
    params = param_names!(params)
    {:lambda, params, code(params, body, sc)}
  end

  # a lexical closure never assigns its own locals: those stay in frames
  defp comp([{:sym, "set!"}, {:sym, name}, _], sc) when is_map_key(sc, name), do: throw(:dynamic)
  defp comp([{:sym, "set!"}, {:sym, name}, value], :dyn), do: {:set, name, compile(value)}
  defp comp([{:sym, "set!"}, {:sym, name}, value], sc), do: {:gset, name, compile(value, sc)}
  defp comp([{:sym, "begin"} | body], sc), do: {:begin, seq(body, sc)}

  # named let: (let loop ((i 0)) ... (loop (+ i 1))) — tail-recursive iteration
  defp comp([{:sym, "let"}, {:sym, name}, bindings | body], sc) do
    {names, forms} = bindings(bindings)
    params = {names, [], nil}
    {:named_let, name, params, seq(forms, sc), code(params, body, sc, name)}
  end

  defp comp([{:sym, "let"}, bindings | body], :dyn) do
    {names, forms} = bindings(bindings)
    {:let, names, seq(forms), seq(body)}
  end

  defp comp([{:sym, "let"}, bindings | body], sc) do
    {names, forms} = bindings(bindings)
    inner = extend(sc, names)
    {:llet, slots(inner, names), seq(forms, sc), seq(body, inner)}
  end

  # let*: each binding sees the previous ones — a fresh frame per binding
  defp comp([{:sym, "let*"}, bindings | body], :dyn) do
    {names, forms} = bindings(bindings)
    {:let_star, Enum.zip(names, seq(forms)), seq(body)}
  end

  defp comp([{:sym, "let*"}, bindings | body], sc) do
    {names, forms} = bindings(bindings)

    {pairs, sc} =
      Enum.zip(names, forms)
      |> Enum.map_reduce(sc, fn {name, form}, sc ->
        inner = extend(sc, [name])
        {{slots(inner, name), compile(form, sc)}, inner}
      end)

    {:llet_star, pairs, seq(body, sc)}
  end

  defp comp([{:sym, "and"} | args], sc), do: {:and, seq(args, sc)}
  defp comp([{:sym, "or"} | args], sc), do: {:or, seq(args, sc)}
  defp comp([{:sym, "cond"} | clauses], sc), do: {:cond, Enum.map(clauses, &clause(&1, sc))}
  defp comp([{:sym, "when"}, test | body], sc), do: {:when, compile(test, sc), seq(body, sc)}
  defp comp([{:sym, "unless"}, test | body], sc), do: {:unless, compile(test, sc), seq(body, sc)}
  defp comp([op | args], sc), do: {:call, compile(op, sc), seq(args, sc), call_name(op)}
  defp comp(other, _sc), do: raise(Error, message: "cannot evaluate: #{inspect(other)}")

  defp clause([{:sym, "else"} | body], sc), do: {:else, seq(body, sc)}
  defp clause([test | body], sc), do: {compile(test, sc), seq(body, sc)}
  # the walker refused a clause only when cond reached it
  defp clause(other, _sc), do: {:fail, %Error{message: "bad cond clause: #{inspect(other)}"}, []}

  defp bindings(bindings), do: Enum.unzip(Enum.map(bindings, fn [{:sym, n}, form] -> {n, form} end))
  defp seq(forms, sc \\ :dyn), do: Enum.map(forms, &compile(&1, sc))
  # a local is read by its slot, an integer the compile gives each name
  # it binds: a new name takes the next one, a shadowing name keeps its own.
  # A map lookup costs ~19 ns with a string key; atoms were as fast as
  # integers but never leave the atom table, and every name agents eval
  # would fill it. Globals stay strings.
  defp extend(sc, names),
    do: Enum.reduce(names, sc, &if(is_map_key(&2, &1), do: &2, else: Map.put(&2, &1, map_size(&2))))

  defp slots(_sc, nil), do: nil
  defp slots(sc, names) when is_list(names), do: Enum.map(names, &:erlang.map_get(&1, sc))
  defp slots(sc, name), do: :erlang.map_get(name, sc)

  # A body that defines nothing and assigns none of the locals it sees
  # never changes a local once bound, so a closure may keep its locals by
  # value: they live in a map passed down the evaluation, {:lex, vars,
  # parent_ref}, a lambda inside captures that map, and each name is known
  # to be a local or a free name when the body compiles. SELF names a named
  # let, which binds itself at each call instead of in a store frame. Every
  # other body keeps store frames, which closures capture and set! shares;
  # inside a lexical body the refusal goes up to the outermost one.
  defp code({req, opt, rest}, body, sc, self \\ nil) do
    if defines?(body), do: throw(:dynamic)
    names = req ++ opt ++ if(rest, do: [rest], else: [])
    names = if self, do: [self | names], else: names
    inner = extend(if(sc == :dyn, do: %{}, else: sc), names)
    {:lcode, seq(body, inner), body, {slots(inner, req), slots(inner, opt), slots(inner, rest), slots(inner, self)}}
  catch
    :dynamic when sc == :dyn -> {:code, seq(body), body}
  end

  defp defines?([{:sym, "quote"} | _]), do: false
  defp defines?([{:sym, "define"} | _]), do: true
  defp defines?(list) when is_list(list), do: any_defines?(list)
  defp defines?(_), do: false

  defp any_defines?([form | rest]), do: defines?(form) or any_defines?(rest)
  defp any_defines?([]), do: false
  defp any_defines?(_improper), do: true

  defp call_name({:sym, name}), do: name
  defp call_name(_), do: "(lambda)"

  # --- run --------------------------------------------------------------------

  defp run({:sym, name}, env, store), do: {Env.lookup(store, env, name), store}
  defp run({:lvar, name}, {:lex, vars, _ref}, store), do: {:erlang.map_get(name, vars), store}
  defp run({:gvar, name}, {:lex, _vars, ref}, store), do: {Env.lookup(store, ref, name), store}

  defp run({:gset, name, value}, {:lex, _vars, ref} = env, store) do
    {val, store} = run(value, env, store)
    {:void, Env.set!(store, ref, name, val)}
  end

  defp run({:llet, names, inits, body}, {:lex, vars, ref} = env, store) do
    {vals, store} = run_args(inits, env, store, [])
    vars = Enum.zip(names, vals) |> Enum.reduce(vars, fn {n, v}, vars -> Map.put(vars, n, v) end)
    run_seq(body, {:lex, vars, ref}, store)
  end

  defp run({:llet_star, pairs, body}, env, store) do
    {env, store} =
      Enum.reduce(pairs, {env, store}, fn {name, form}, {{:lex, vars, ref} = env, store} ->
        {val, store} = run(form, env, store)
        {{:lex, Map.put(vars, name, val), ref}, store}
      end)

    run_seq(body, env, store)
  end

  defp run({:call, op, arg_forms, name}, env, store) do
    {f, store} = run(op, env, store)
    {args, store} = run_args(arg_forms, env, store, [])

    # an armed profiler times the call under the name it was called by;
    # disarmed, this is one persistent_term read and the tail call stays
    case Compos.Scheme.Profile.table() do
      nil -> apply_fn(f, args, store)
      table -> Compos.Scheme.Profile.call(table, name, fn -> apply_fn(f, args, store) end)
    end
  end

  defp run({:if, c, t, e}, env, store) do
    case run(c, env, store) do
      {false, store} -> run(e, env, store)
      {_, store} -> run(t, env, store)
    end
  end

  defp run({:quote, form}, _env, store), do: {form, store}
  defp run({:lambda, params, code}, env, store), do: {{:closure, params, code, env}, store}

  defp run({:define, name, value}, env, store) do
    {val, store} = run(value, env, store)
    {:void, Env.define(store, env, name, val)}
  end

  defp run({:set, name, value}, env, store) do
    {val, store} = run(value, env, store)
    {:void, Env.set!(store, env, name, val)}
  end

  defp run({:begin, body}, env, store), do: run_seq(body, env, store)

  defp run({:named_let, _name, params, inits, {:lcode, _, _, _} = code}, env, store) do
    {vals, store} = run_args(inits, env, store, [])
    apply_fn({:closure, params, code, env}, vals, store)
  end

  defp run({:named_let, name, params, inits, code}, env, store) do
    {vals, store} = run_args(inits, env, store, [])
    {frame, store} = Env.new_frame(store, env)
    closure = {:closure, params, code, frame}
    apply_fn(closure, vals, Env.define(store, frame, name, closure))
  end

  defp run({:let, names, inits, body}, env, store) do
    {vals, store} = run_args(inits, env, store, [])
    {frame, store} = Env.new_frame(store, env, Map.new(Enum.zip(names, vals)))
    run_seq(body, frame, store)
  end

  defp run({:let_star, bindings, body}, env, store) do
    {frame, store} =
      Enum.reduce(bindings, {env, store}, fn {name, form}, {env, store} ->
        {val, store} = run(form, env, store)
        Env.new_frame(store, env, %{name => val})
      end)

    run_seq(body, frame, store)
  end

  defp run({:and, forms}, env, store), do: run_and(forms, env, store)
  defp run({:or, forms}, env, store), do: run_or(forms, env, store)
  defp run({:cond, clauses}, env, store), do: run_cond(clauses, env, store)

  defp run({:when, test, body}, env, store) do
    case run(test, env, store) do
      {false, store} -> {:void, store}
      {_, store} -> run_seq(body, env, store)
    end
  end

  defp run({:unless, test, body}, env, store) do
    case run(test, env, store) do
      {false, store} -> run_seq(body, env, store)
      {_, store} -> {:void, store}
    end
  end

  defp run({:fail, e, stacktrace}, _env, _store), do: reraise(e, stacktrace)

  # a number, a string or a boolean evaluates to itself
  defp run(value, _env, store), do: {value, store}

  @doc "Apply a Scheme callable to already-evaluated args."
  def apply_fn({:interposed, original, wrapper}, args, store) do
    apply_fn(wrapper, [original, args], store)
  end

  def apply_fn({:closure, {req, opt, rest}, {:code, body, source}, closure_env}, args, store) do
    count_nesting!(source)
    vars = bind_params!(req, opt, rest, args)
    {frame, store} = Env.new_frame(store, closure_env, vars)
    run_seq(body, frame, store)
  end

  # slice 1's closure, kept for a live daemon that hot-loads this module
  def apply_fn({:closure, {req, opt, rest}, {:lcode, body, source}, env}, args, store) do
    count_nesting!(source)
    run_seq(body, lex(env, bind_params!(req, opt, rest, args)), store)
  end

  def apply_fn({:closure, _params, {:lcode, body, source, {req, opt, rest, self}}, env} = f, args, store) do
    count_nesting!(source)
    vars = bind_params!(req, opt, rest, args)
    vars = if self == nil or is_map_key(vars, self), do: vars, else: Map.put(vars, self, f)
    run_seq(body, lex(env, vars), store)
  end

  # A closure made before the compiler, which a live daemon still holds
  # after it hot-loaded this module, has a source body: compile per call.
  def apply_fn({:closure, params, body, env}, args, store) when is_list(body),
    do: apply_fn({:closure, params, code(params, body, :dyn), env}, args, store)

  # A builtin fed bad arguments must surface as a Scheme error, not a raw
  # Elixir exception: raw exceptions crash the hosting GenServer (the whole
  # editor Session died to a (string-prefix? s #f) once) — Error is caught
  # by the usual error paths instead.
  # The core builtins are pure value functions: none of them can store a
  # closure into Elixir state, so an argument cannot escape through them.
  # The flush covers the eval result and the shared-tier writes. Without
  # this exemption every (car es) over a large list rescans the whole
  # tail, and a catalog walk turns quadratic.
  @non_retaining Compos.Scheme.Builtins.all() |> Map.new(fn {name, _} -> {name, true} end)

  def apply_fn({:builtin, name, fun}, args, store) when is_function(fun, 1) do
    # a closure handed to a host primitive escapes Scheme (command tables,
    # hooks, buffer locals): publish its frames before the host can call it
    store = promote_primitive_args(name, args, store)
    {builtin_apply(name, fn -> fun.(args) end), store}
  end

  def apply_fn({:builtin, name, fun}, args, store) when is_function(fun, 2) do
    store = promote_primitive_args(name, args, store)
    builtin_apply(name, fn -> fun.(args, store) end)
  end

  def apply_fn(other, _args, _store) do
    raise Error, message: "not a function: #{inspect(other)}"
  end

  defp promote_primitive_args(name, args, store) do
    if is_map_key(@non_retaining, name) do
      store
    else
      if guard = Process.get(:compos_scheme_host_guard), do: guard.(name, args)
      Env.promote(store, args)
    end
  end

  defp builtin_apply(name, thunk) do
    thunk.()
  rescue
    e in Error ->
      reraise e, __STACKTRACE__

    e in [
      ArgumentError,
      FunctionClauseError,
      MatchError,
      CaseClauseError,
      ArithmeticError,
      KeyError
    ] ->
      reraise Error,
              [message: "#{name}: #{Exception.message(e)}"],
              __STACKTRACE__

    # Any other exception is a fault in the daemon, not in the caller's
    # code. The text names the primitive and says so, and the caller can
    # take another path. The log line reaches the error feed, and
    # self-healing files the fault.
    e ->
      text = "#{name}: daemon fault (#{inspect(e.__struct__)}): #{Exception.message(e)}"
      Logger.error(text)
      reraise Error, [message: text], __STACKTRACE__
  end

  # --- helpers ---------------------------------------------------------------

  defp lex({:lex, outer, ref}, vars), do: {:lex, Map.merge(outer, vars), ref}
  defp lex(ref, vars), do: {:lex, vars, ref}

  defp run_args([], _env, store, acc), do: {Enum.reverse(acc), store}

  defp run_args([form | rest], env, store, acc) do
    {val, store} = run(form, env, store)
    run_args(rest, env, store, [val | acc])
  end

  # last form is in tail position
  defp run_seq([form], env, store), do: run(form, env, store)

  defp run_seq([form | rest], env, store) do
    {_val, store} = run(form, env, store)
    run_seq(rest, env, store)
  end

  defp run_seq([], _env, store), do: {:void, store}

  defp run_cond([], _env, store), do: {:void, store}
  defp run_cond([{:else, body} | _rest], env, store), do: run_seq(body, env, store)
  defp run_cond([{:fail, e, st} | _rest], _env, _store), do: reraise(e, st)

  defp run_cond([{test, body} | rest], env, store) do
    case run(test, env, store) do
      {false, store} -> run_cond(rest, env, store)
      {val, store} when body == [] -> {val, store}
      {_, store} -> run_seq(body, env, store)
    end
  end

  defp run_and([], _env, store), do: {true, store}
  defp run_and([last], env, store), do: run(last, env, store)

  defp run_and([form | rest], env, store) do
    case run(form, env, store) do
      {false, store} -> {false, store}
      {_, store} -> run_and(rest, env, store)
    end
  end

  defp run_or([], _env, store), do: {false, store}
  defp run_or([last], env, store), do: run(last, env, store)

  defp run_or([form | rest], env, store) do
    case run(form, env, store) do
      {false, store} -> run_or(rest, env, store)
      found -> found
    end
  end

  defp param_names!(params) do
    params
    |> dotted_params()
    |> Enum.map(fn
      {:sym, name} -> name
      other -> raise Error, message: "bad parameter: #{inspect(other)}"
    end)
    |> parse_params!([], :req)
  end

  # R7RS rest formals: (a b . r) and a bare symbol r are (a b &rest r)
  # and (&rest r); the reader gives them as an improper list and a symbol
  defp dotted_params({:sym, _} = rest), do: [{:sym, "&rest"}, rest]
  defp dotted_params([p | more]), do: [p | dotted_params(more)]
  defp dotted_params(params), do: params

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

  defp rest_name!(other),
    do: raise(Error, message: "&rest takes exactly one name, got: #{inspect(other)}")

  # required parameters only, the common case: one walk binds them
  defp bind_params!(req, [], nil, args), do: bind_required(req, args, %{}, req, args)

  defp bind_params!(req, opt, rest, args) do
    nreq = length(req)
    nargs = length(args)
    max = if rest, do: nil, else: nreq + length(opt)

    cond do
      nargs < nreq ->
        raise Error, message: "arity mismatch: expected at least #{nreq}, got #{nargs}"

      max != nil and nargs > max ->
        raise Error, message: "arity mismatch: expected at most #{max}, got #{nargs}"

      true ->
        {req_args, more} = Enum.split(args, nreq)
        {opt_args, rest_args} = Enum.split(more, length(opt))
        opt_vals = opt_args ++ List.duplicate(false, length(opt) - length(opt_args))

        vars = Map.new(Enum.zip(req, req_args) ++ Enum.zip(opt, opt_vals))
        if rest, do: Map.put(vars, rest, rest_args), else: vars
    end
  end

  defp bind_required([name | names], [arg | args], vars, req, all),
    do: bind_required(names, args, Map.put(vars, name, arg), req, all)

  defp bind_required([], [], vars, _req, _all), do: vars

  defp bind_required(_, _, _, req, all),
    do: raise(Error, message: "arity mismatch: expected #{length(req)}, got #{length(all)}")
end
