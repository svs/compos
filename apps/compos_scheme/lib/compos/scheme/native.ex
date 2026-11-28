defmodule Compos.Scheme.Native do
  @moduledoc """
  Core Erlang backend for lexical lambdas.

  `Eval` compiles a form into tagged tuples. A top-level lambda whose body
  is lexical (`:lcode`: it defines nothing and assigns none of its own
  locals) lowers here further, into a Core Erlang module that the BEAM
  compiler turns into bytecode:

    * locals are BEAM variables, and an inner lambda is a native BEAM
      closure over them, so no frame or map is built per call;
    * a call to the enclosing named let is a direct local call;
    * free names are looked up through the store, as before (`Eval.gvar/3`),
      so `define`, `set!` of a global, interpose and the call gate all hold;
    * the store is threaded through every call, exactly as in `Eval.run`.

  A native closure is `{:closure, params, {:ncode, fun, source}, ref}`:
  the same shape as the interpreter's, so printing, `function-source`,
  the GC and promotion see it as before. The GC reads the frames a native
  closure holds from the fun's environment (`Env.closure_refs/2`).

  Modules are named by the hash of what they compile, and never purged.
  A redefinition compiles a new module and the old closures keep their
  own code, so a reload never kills a process that still runs the old
  version. Ad-hoc evals stay interpreted: compiling is on only for
  `:always`, or for `:packages` inside `with_native/1`.

  `config :compos_scheme, native: :off | :packages | :always`.
  """

  require Logger

  alias Compos.Scheme.Eval

  @flag :compos_scheme_native

  # Bumped when the lowering changes, so a hot reload compiles new modules
  # instead of reusing the ones the old lowering loaded.
  @version 3

  # the lambdas a batch/1 queues, in the process dictionary
  @batch :compos_scheme_native_batch
  # the {file, first, last} of the top-level form compiling now, or nil
  @where :compos_scheme_native_where

  # Extra :compile options; config :compos_scheme, native_opts: [...] overrides.
  # The optimisation passes cost 3x the compile time (5.5 ms a lambda against
  # 1.9) and bought no speed on the benchmarks: the code calls out to Eval
  # and Env for every free name, so there is little for them to improve.
  @opts [:no_ssa_opt, :no_bool_opt, :no_share_opt, :no_bsm_opt, :no_fun_opt, :no_recv_opt, :no_postopt]

  # the core builtins a call inlines, by {name, arity}; list inlines at any arity
  @inlined Map.new(
             [
               {"+", 2}, {"-", 1}, {"-", 2}, {"*", 2},
               {"=", 2}, {"<", 2}, {">", 2}, {"<=", 2}, {">=", 2},
               {"eq?", 2}, {"eqv?", 2}, {"equal?", 2}, {"not", 1},
               {"cons", 2}, {"car", 1}, {"cdr", 1}, {"null?", 1}, {"pair?", 1},
               {"zero?", 1}, {"number?", 1}, {"integer?", 1}, {"string?", 1}, {"symbol?", 1}
             ],
             &{&1, true}
           )

  defmodule Unsupported do
    defexception [:message]
  end

  @doc "True when a lambda compiled now should lower to BEAM code."
  def enabled? do
    case Application.get_env(:compos_scheme, :native, :off) do
      :always -> true
      :packages -> Process.get(@flag) == true
      _ -> false
    end
  end

  @doc "Run FUN with native compilation on in this process (a package load)."
  def with_native(fun) do
    prev = Process.put(@flag, true)

    try do
      fun.()
    after
      if prev, do: Process.put(@flag, prev), else: Process.delete(@flag)
    end
  end

  @doc "Compile a top-level lexical lambda. Answers `{:ok, module}` or `:error`."
  def compile(params, {:lcode, _body, _source, _slots} = code) do
    mod = module_name("", [params, code])

    case load(mod, fn -> module(mod, [{:make, params, code, nil}]) end) do
      {:ok, mod} -> {:ok, {mod, :make}}
      :error -> :error
    end
  rescue
    e in Unsupported ->
      Logger.debug("native: #{e.message}")
      :error

    e ->
      Logger.warning("native compile failed: #{Exception.message(e)}")
      :error
  end

  @doc """
  Run FUN, which compiles forms, and lower every top-level lambda it
  compiles into one module: the per-module cost of the BEAM compiler is
  paid once for a file instead of once per definition. Answers `{value of
  FUN, table}`, the table mapping each queued index to `{module, function}`,
  or to nothing for a lambda that stays interpreted. See `resolve/2`.
  """
  def batch(fun) do
    prev = Process.put(@batch, [])

    try do
      value = fun.()
      entries = Process.get(@batch) |> Enum.reverse()
      {value, compile_batch(entries)}
    after
      if prev, do: Process.put(@batch, prev), else: Process.delete(@batch)
    end
  end

  @doc "True inside `batch/1`: a lambda queues instead of compiling."
  def batching?, do: is_list(Process.get(@batch))

  @doc "Queue a lambda in the running batch; answers its index."
  def enqueue(params, code) do
    queue = Process.get(@batch)
    Process.put(@batch, [{params, code, Process.get(@where)} | queue])
    length(queue)
  end

  @doc """
  Run FUN, which compiles the top-level form on lines FIRST..LAST of FILE:
  the lambdas it queues keep that place instead of their source.
  """
  def at(file, first, last, fun) when is_binary(file) and is_integer(first) and is_integer(last) do
    prev = Process.put(@where, {file, first, last})

    try do
      fun.()
    after
      if prev, do: Process.put(@where, prev), else: Process.delete(@where)
    end
  end

  def at(_file, _first, _last, fun), do: fun.()

  defp compile_batch([]), do: %{}

  defp compile_batch(entries) do
    mod = module_name("b", entries)

    # the k-th lambda of its top-level form: what source/1 finds again
    {named, _} =
      entries
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {{p, c, where}, i}, seen ->
        k = Map.get(seen, where, 0)
        {{make_name(i), p, c, where && Tuple.insert_at(where, tuple_size(where), k)}, Map.put(seen, where, k + 1)}
      end)

    case load(mod, fn -> module(mod, named) end) do
      {:ok, mod} -> Map.new(mod.compiled(), &{&1, {mod, make_name(&1)}})
      :error -> %{}
    end
  rescue
    e in Unsupported ->
      Logger.debug("native: #{e.message}")
      %{}

    e ->
      Logger.warning("native batch compile failed: #{Exception.message(e)}")
      %{}
  end

  defp make_name(i), do: String.to_atom("make_" <> Integer.to_string(i))

  defp module_name(kind, term) do
    key = {@version, :erlang.system_info(:otp_release), term}
    hash = :erlang.md5(:erlang.term_to_binary(key)) |> Base.encode16(case: :lower)
    String.to_atom("compos_scheme_native_" <> kind <> hash)
  end

  @doc false
  # the closure a compiled lambda node makes over ENV
  def make({mod, fun}, env), do: apply(mod, fun, [env])
  # a node compiled before batches, which a live daemon may still hold
  def make(mod, env) when is_atom(mod), do: mod.make(env)

  # Load MOD: already loaded, else from the disk cache, else compile the
  # Core Erlang BUILD answers and write the cache. BUILD runs only on a miss.
  defp load(mod, build) do
    cond do
      :erlang.module_loaded(mod) ->
        {:ok, mod}

      bin = cached(mod) ->
        load_binary(mod, bin)

      true ->
        opts =
          [:from_core, :binary, :return_errors, :no_spawn_compiler_process] ++
            Application.get_env(:compos_scheme, :native_opts, @opts)

        case :compile.forms(build.(), opts) do
          {:ok, ^mod, bin} ->
            cache!(mod, bin)
            load_binary(mod, bin)

          other ->
            Logger.warning("native compile refused: #{inspect(other, limit: 20)}")
            :error
        end
    end
  end

  defp load_binary(mod, bin) do
    case :code.load_binary(mod, ~c"compos_scheme_native", bin) do
      {:module, ^mod} -> {:ok, mod}
      # another process loaded the same code first
      {:error, _} -> if :erlang.module_loaded(mod), do: {:ok, mod}, else: :error
    end
  end

  # The disk cache: a .beam per module, named by the hash of what it
  # compiles, so a later boot loads it instead of compiling. nil turns it off.
  defp cache_dir, do: Application.get_env(:compos_scheme, :native_cache, default_cache())

  defp default_cache,
    do: Path.join(System.tmp_dir!(), "compos-scheme-native-otp" <> List.to_string(:erlang.system_info(:otp_release)))

  defp cached(mod) do
    with dir when is_binary(dir) <- cache_dir(),
         {:ok, bin} <- File.read(Path.join(dir, Atom.to_string(mod) <> ".beam")) do
      bin
    else
      _ -> nil
    end
  end

  defp cache!(mod, bin) do
    with dir when is_binary(dir) <- cache_dir() do
      path = Path.join(dir, Atom.to_string(mod) <> ".beam")
      tmp = path <> "." <> Integer.to_string(System.unique_integer([:positive]))

      # write and rename, so a reader never sees half a file
      with :ok <- File.mkdir_p(dir), :ok <- File.write(tmp, bin), :ok <- File.rename(tmp, path) do
        :ok
      else
        _ -> File.rm(tmp)
      end
    end
  rescue
    _ -> :ok
  end

  # --- runtime helpers the generated code calls ---------------------------

  @doc false
  def arity_error(nreq, args),
    do: raise(Eval.Error, message: "arity mismatch: expected #{nreq}, got #{length(args)}")

  @doc false
  # bind &optional and &rest: a list of exactly nreq + nopt (+ 1) values
  def spread(nreq, nopt, rest?, args) do
    nargs = length(args)

    cond do
      nargs < nreq ->
        raise Eval.Error, message: "arity mismatch: expected at least #{nreq}, got #{nargs}"

      not rest? and nargs > nreq + nopt ->
        raise Eval.Error, message: "arity mismatch: expected at most #{nreq + nopt}, got #{nargs}"

      true ->
        {fixed, more} = Enum.split(args, nreq + nopt)
        fixed = fixed ++ List.duplicate(false, nreq + nopt - length(fixed))
        if rest?, do: fixed ++ [more], else: fixed
    end
  end

  @doc false
  def fail(e), do: raise(e)

  # --- lowering -------------------------------------------------------------

  defp module(mod, entries) do
    Process.put(:compos_native_n, 0)

    # a lambda that does not lower stays interpreted; the others still compile
    {defs, ok} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{name, params, code, place}, i}, {defs, ok} ->
        try do
          ref = var()
          ctx = %{vars: %{}, ref: ref, place: place, inner: inner_index(code)}
          {f, def} = lambda_def(params, code, ctx)
          make = :cerl.c_fun([ref], :cerl.c_letrec([{f, def}], closure_tuple(f, params, code, ctx)))
          {[{:cerl.c_fname(name, 1), make} | defs], [i | ok]}
        rescue
          e in Unsupported ->
            Logger.debug("native: #{e.message}")
            {defs, ok}
        end
      end)

    if ok == [], do: raise(Unsupported, message: "nothing in the batch lowers")

    x = var()
    info0 = :cerl.c_fun([], :cerl.c_call(atom(:erlang), atom(:get_module_info), [atom(mod)]))
    info1 = :cerl.c_fun([x], :cerl.c_call(atom(:erlang), atom(:get_module_info), [atom(mod), x]))

    defs =
      Enum.reverse(defs) ++
        [
          {:cerl.c_fname(:compiled, 0), :cerl.c_fun([], lit(Enum.reverse(ok)))},
          {:cerl.c_fname(:module_info, 0), info0},
          {:cerl.c_fname(:module_info, 1), info1}
        ]

    :cerl.c_module(atom(mod), Enum.map(defs, &elem(&1, 0)), [], defs)
  end

  # One lambda: a local function of (Args, Store) answering {Value, Store}.
  defp lambda_def({_req, opt, rest} = params, {:lcode, body, _source, {rs, os, rst, self}} = code, ctx) do
    f = :cerl.c_fname(fname(), 2)
    args = var()
    s = var()
    slots = rs ++ os ++ if(rst, do: [rst], else: [])
    vs = Enum.map(slots, fn _ -> var() end)

    ctx = if self, do: put_var(ctx, self, {:self, f, params, code, length(rs), opt == [] and rest == nil}), else: ctx
    ctx = slots |> Enum.zip(vs) |> Enum.reduce(ctx, fn {sl, v}, c -> put_var(c, sl, v) end)

    run = tail(seq(body, ctx, s), s)

    bound =
      if opt == [] and rest == nil do
        other = var()

        :cerl.c_case(args, [
          clause(list(vs), run),
          clause(other, call(__MODULE__, :arity_error, [lit(length(rs)), other]))
        ])
      else
        spread = call(__MODULE__, :spread, [lit(length(rs)), lit(length(os)), lit(rst != nil), args])
        :cerl.c_case(spread, [clause(list(vs), run)])
      end

    entry = :cerl.c_seq(call(Eval, :count_nesting!, [lit(source_of(code, ctx))]), bound)
    {f, :cerl.c_fun([args, s], entry)}
  end

  defp closure_tuple(f, params, code, ctx),
    do: :cerl.c_tuple([atom(:closure), lit(params), :cerl.c_tuple([atom(:ncode), f, lit(source_of(code, ctx))]), ctx.ref])

  # What a module keeps for the source of CODE. With a place, a locator
  # {:at, file, first, last, k, j, hash}: the j-th lambda inside (0 is
  # itself) the k-th top-level lambda of the form on those lines, and the
  # hash of its source, so a file changed since cannot answer wrong.
  # Without one (an eval with no file), the source itself.
  defp source_of({:lcode, _body, source, _slots} = code, %{place: {file, first, last, k}} = ctx),
    do: {:at, file, first, last, k, Map.get(ctx.inner, code, 0), :erlang.phash2(source)}

  defp source_of({:lcode, _body, source, _slots}, _ctx), do: source

  # every lambda body inside CODE, numbered from 1 in pre-order
  defp inner_index({:lcode, body, _source, _slots}) do
    body |> lcodes([]) |> Enum.reverse() |> Enum.with_index(1) |> Enum.reverse() |> Map.new()
  end

  @doc false
  def lcodes({:lcode, body, _source, _slots} = code, acc), do: lcodes(body, [code | acc])
  def lcodes({:quote, _}, acc), do: acc
  def lcodes({:fail, _, _}, acc), do: acc
  def lcodes(node, acc) when is_tuple(node), do: node |> Tuple.to_list() |> lcodes(acc)
  def lcodes([head | tail], acc), do: lcodes(tail, lcodes(head, acc))
  def lcodes(_leaf, acc), do: acc

  @doc """
  The source a locator names, read from its file: the body forms, as
  `Eval.source/1` answers for an interpreted closure. A file that no longer
  holds that source answers a one-line note instead.
  """
  def source({:at, file, first, last, k, j, hash}) do
    with {:ok, text} <- File.read(file),
         lines = text |> String.split("\n") |> Enum.slice((first - 1)..(last - 1)//1),
         [form] <- Compos.Scheme.Reader.read_all(Enum.join(lines, "\n")),
         {:lcode, _, _, _} = top <- top_lambda(form, k),
         {:lcode, _, source, _} <- if(j == 0, do: top, else: Enum.at(top |> lcodes([]) |> Enum.reverse() |> tl(), j - 1)),
         true <- :erlang.phash2(source) == hash do
      source
    else
      _ -> ["source not found: #{file}:#{first} changed since it loaded"]
    end
  rescue
    _ -> ["source not found: #{file}:#{first}"]
  end

  # compile FORM again without building anything: the K-th lambda it queues
  defp top_lambda(form, k) do
    prev = Process.put(@batch, [])

    try do
      # batching already: the compile queues and builds nothing
      Eval.compile_forms([form])

      case Process.get(@batch) |> Enum.reverse() |> Enum.at(k) do
        {_params, code, _where} -> code
        nil -> nil
      end
    after
      if prev, do: Process.put(@batch, prev), else: Process.delete(@batch)
    end
  end

  # A node lowers to {:pure, expr}, a value that leaves the store alone, or
  # {:eff, expr}, an expression that answers {Value, Store}. S is the
  # variable that holds the store where the node runs.
  defp lower({:lvar, slot}, ctx, _s) do
    case Map.fetch!(ctx.vars, slot) do
      {:self, f, params, code, _n, _plain} -> {:pure, closure_tuple(f, params, code, ctx)}
      v -> {:pure, v}
    end
  end

  defp lower({:gvar, name}, ctx, s), do: {:pure, call(Eval, :gvar, [s, ctx.ref, lit(name)])}
  defp lower({:quote, form}, _ctx, _s), do: {:pure, lit(form)}
  defp lower(x, _ctx, _s) when is_number(x) or is_binary(x) or is_boolean(x), do: {:pure, lit(x)}

  defp lower({:if, c, t, e}, ctx, s) do
    {:eff,
     bind(lower(c, ctx, s), s, fn v, s ->
       branch(v, tail(lower(e, ctx, s), s), tail(lower(t, ctx, s), s))
     end)}
  end

  defp lower({:begin, body}, ctx, s), do: seq(body, ctx, s)
  defp lower({:and, []}, _ctx, _s), do: {:pure, atom(true)}
  defp lower({:and, [x]}, ctx, s), do: lower(x, ctx, s)

  defp lower({:and, [x | more]}, ctx, s) do
    {:eff,
     bind(lower(x, ctx, s), s, fn v, s ->
       branch(v, :cerl.c_tuple([atom(false), s]), tail(lower({:and, more}, ctx, s), s))
     end)}
  end

  defp lower({:or, []}, _ctx, _s), do: {:pure, atom(false)}
  defp lower({:or, [x]}, ctx, s), do: lower(x, ctx, s)

  defp lower({:or, [x | more]}, ctx, s) do
    {:eff,
     bind(lower(x, ctx, s), s, fn v, s ->
       branch(v, tail(lower({:or, more}, ctx, s), s), :cerl.c_tuple([v, s]))
     end)}
  end

  defp lower({:cond, clauses}, ctx, s), do: lower_cond(clauses, ctx, s)

  defp lower({:when, test, body}, ctx, s) do
    {:eff,
     bind(lower(test, ctx, s), s, fn v, s ->
       branch(v, :cerl.c_tuple([atom(:void), s]), tail(seq(body, ctx, s), s))
     end)}
  end

  defp lower({:unless, test, body}, ctx, s) do
    {:eff,
     bind(lower(test, ctx, s), s, fn v, s ->
       branch(v, tail(seq(body, ctx, s), s), :cerl.c_tuple([atom(:void), s]))
     end)}
  end

  defp lower({:llet, slots, inits, body}, ctx, s) do
    {:eff,
     bind_all(inits, ctx, s, [], fn vals, s ->
       ctx = slots |> Enum.zip(vals) |> Enum.reduce(ctx, fn {sl, v}, c -> put_var(c, sl, v) end)
       tail(seq(body, ctx, s), s)
     end)}
  end

  defp lower({:llet_star, pairs, body}, ctx, s), do: {:eff, star(pairs, body, ctx, s)}

  defp lower({:lambda, params, code, _keep}, ctx, _s) do
    {f, def} = lambda_def(params, code, ctx)
    {:pure, :cerl.c_letrec([{f, def}], closure_tuple(f, params, code, ctx))}
  end

  defp lower({:named_let, _name, params, inits, {:lcode, _, _, _} = code}, ctx, s) do
    {f, def} = lambda_def(params, code, ctx)

    {:eff,
     bind_all(inits, ctx, s, [], fn vals, s ->
       :cerl.c_letrec([{f, def}], :cerl.c_apply(f, [list(vals), s]))
     end)}
  end

  defp lower({:gset, name, value}, ctx, s) do
    {:eff,
     bind(lower(value, ctx, s), s, fn v, s ->
       s2 = var()
       :cerl.c_let([s2], call(Compos.Scheme.Env, :set!, [s, ctx.ref, lit(name), v]), :cerl.c_tuple([atom(:void), s2]))
     end)}
  end

  # a call to the enclosing named let, with its own arity, is a local call
  defp lower({:call, {:lvar, slot}, args, name}, ctx, s) do
    case Map.fetch!(ctx.vars, slot) do
      {:self, f, _params, _code, n, true} when length(args) == n ->
        {:eff, bind_all(args, ctx, s, [], fn vals, s -> :cerl.c_apply(f, [list(vals), s]) end)}

      _ ->
        generic_call({:lvar, slot}, args, name, ctx, s)
    end
  end

  # A core builtin inlines to its BIF while the name still holds that builtin.
  # The name is looked up as before, so a redefinition, an interpose or a
  # refusal of the call gate holds: any value but the builtin itself, or an
  # argument its guard refuses, takes the generic call and its own error.
  defp lower({:call, {:gvar, name} = op, args, cname}, ctx, s)
       when is_map_key(@inlined, {name, length(args)}) or name == "list" do
    {:eff,
     bind(lower(op, ctx, s), s, fn f, s ->
       bind_all(args, ctx, s, [], fn vals, s ->
         {guard, body} = inline(name, vals)
         # a binary is no literal pattern for the BEAM compiler: the guard compares it
         n = var()
         pat = :cerl.c_tuple([atom(:builtin), n, var()])
         guard = bif(:and, [bif(:"=:=", [n, lit(name)]), guard])
         slow = call(Eval, :call_native, [f, list(vals), s, lit(cname)])
         :cerl.c_case(f, [:cerl.c_clause([pat], guard, :cerl.c_tuple([body, s])), clause(var(), slow)])
       end)
     end)}
  end

  defp lower({:call, op, args, name}, ctx, s), do: generic_call(op, args, name, ctx, s)
  defp lower({:fail, e, _stack}, _ctx, _s), do: {:eff, call(__MODULE__, :fail, [lit(e)])}
  defp lower(other, _ctx, _s), do: raise(Unsupported, message: "cannot lower #{inspect(other, limit: 5)}")

  defp generic_call(op, args, name, ctx, s) do
    {:eff,
     bind(lower(op, ctx, s), s, fn f, s ->
       bind_all(args, ctx, s, [], fn vals, s ->
         call(Eval, :call_native, [f, list(vals), s, lit(name)])
       end)
     end)}
  end

  # {guard, body} of an inlined builtin over argument VALS, vars or literals.
  # Each matches the builtin in Builtins for every argument its guard takes.
  defp inline("list", vals), do: {atom(true), list(vals)}
  defp inline("+", [a, b]), do: {numbers(a, b), bif(:+, [a, b])}
  defp inline("-", [a]), do: {bif(:is_number, [a]), bif(:-, [a])}
  defp inline("-", [a, b]), do: {numbers(a, b), bif(:-, [a, b])}
  defp inline("*", [a, b]), do: {numbers(a, b), bif(:*, [a, b])}
  defp inline("=", [a, b]), do: {atom(true), bif(:==, [a, b])}
  defp inline("<", [a, b]), do: {atom(true), bif(:<, [a, b])}
  defp inline(">", [a, b]), do: {atom(true), bif(:>, [a, b])}
  defp inline("<=", [a, b]), do: {atom(true), bif(:"=<", [a, b])}
  defp inline(">=", [a, b]), do: {atom(true), bif(:>=, [a, b])}
  defp inline("eq?", [a, b]), do: {atom(true), bif(:"=:=", [a, b])}
  defp inline("eqv?", [a, b]), do: {atom(true), bif(:"=:=", [a, b])}
  defp inline("equal?", [a, b]), do: {atom(true), bif(:==, [a, b])}
  defp inline("not", [a]), do: {atom(true), bif(:==, [a, atom(false)])}
  defp inline("cons", [a, b]), do: {atom(true), :cerl.c_cons(a, b)}
  defp inline("car", [a]), do: {pair(a), bif(:hd, [a])}
  defp inline("cdr", [a]), do: {pair(a), bif(:tl, [a])}
  defp inline("null?", [a]), do: {atom(true), bif(:"=:=", [a, :cerl.c_nil()])}
  defp inline("pair?", [a]), do: {atom(true), :cerl.c_case(a, [clause(:cerl.c_cons(var(), var()), atom(true)), clause(var(), atom(false))])}
  defp inline("zero?", [a]), do: {atom(true), bif(:==, [a, lit(0)])}
  defp inline("number?", [a]), do: {atom(true), bif(:is_number, [a])}
  defp inline("integer?", [a]), do: {atom(true), bif(:is_integer, [a])}
  defp inline("string?", [a]), do: {atom(true), bif(:is_binary, [a])}

  defp inline("symbol?", [a]),
    do: {atom(true), :cerl.c_case(a, [clause(:cerl.c_tuple([atom(:sym), var()]), atom(true)), clause(var(), atom(false))])}

  defp bif(name, args), do: call(:erlang, name, args)
  defp numbers(a, b), do: bif(:and, [bif(:is_number, [a]), bif(:is_number, [b])])
  defp pair(a), do: bif(:and, [bif(:is_list, [a]), bif(:"=/=", [a, :cerl.c_nil()])])

  defp lower_cond([], _ctx, _s), do: {:pure, atom(:void)}
  defp lower_cond([{:else, body} | _], ctx, s), do: seq(body, ctx, s)
  defp lower_cond([{:fail, e, st} | _], ctx, s), do: lower({:fail, e, st}, ctx, s)

  defp lower_cond([{test, body} | rest], ctx, s) do
    {:eff,
     bind(lower(test, ctx, s), s, fn v, s ->
       found = if body == [], do: :cerl.c_tuple([v, s]), else: tail(seq(body, ctx, s), s)
       branch(v, tail(lower_cond(rest, ctx, s), s), found)
     end)}
  end

  defp star([], body, ctx, s), do: tail(seq(body, ctx, s), s)

  defp star([{slot, form} | more], body, ctx, s),
    do: bind(lower(form, ctx, s), s, fn v, s -> star(more, body, put_var(ctx, slot, v), s) end)

  defp seq([], _ctx, _s), do: {:pure, atom(:void)}
  defp seq([x], ctx, s), do: lower(x, ctx, s)
  defp seq([x | more], ctx, s), do: {:eff, bind(lower(x, ctx, s), s, fn _v, s -> tail(seq(more, ctx, s), s) end)}

  defp bind_all([], _ctx, s, acc, k), do: k.(Enum.reverse(acc), s)

  defp bind_all([x | more], ctx, s, acc, k),
    do: bind(lower(x, ctx, s), s, fn v, s -> bind_all(more, ctx, s, [v | acc], k) end)

  # run R, then K with its value and the store after it
  defp bind({:pure, expr}, s, k) do
    if :cerl.is_c_var(expr) or :cerl.is_literal(expr) do
      k.(expr, s)
    else
      v = var()
      :cerl.c_let([v], expr, k.(v, s))
    end
  end

  defp bind({:eff, expr}, _s, k) do
    v = var()
    s = var()
    :cerl.c_case(expr, [clause(:cerl.c_tuple([v, s]), k.(v, s))])
  end

  defp tail({:pure, expr}, s), do: :cerl.c_tuple([expr, s])
  defp tail({:eff, expr}, _s), do: expr

  # Scheme's only false value is #f
  defp branch(v, if_false, if_true),
    do: :cerl.c_case(v, [clause(atom(false), if_false), clause(var(), if_true)])

  defp clause(pat, body), do: :cerl.c_clause([pat], body)
  defp put_var(ctx, slot, v), do: %{ctx | vars: Map.put(ctx.vars, slot, v)}
  defp call(mod, name, args), do: :cerl.c_call(atom(mod), atom(name), args)
  defp atom(a), do: :cerl.c_atom(a)
  defp list(xs), do: :cerl.make_list(xs)

  defp lit(term) do
    :cerl.abstract(term)
  rescue
    _ -> raise Unsupported, message: "no literal for #{inspect(term, limit: 5)}"
  end

  defp var do
    n = Process.get(:compos_native_n, 0) + 1
    Process.put(:compos_native_n, n)
    :cerl.c_var(n)
  end

  defp fname do
    n = Process.get(:compos_native_n, 0) + 1
    Process.put(:compos_native_n, n)
    String.to_atom("l" <> Integer.to_string(n))
  end
end
