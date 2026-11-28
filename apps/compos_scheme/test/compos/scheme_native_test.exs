defmodule Compos.SchemeNativeTest do
  @moduledoc """
  The Core Erlang backend answers what the interpreter answers.

  Each program runs twice, interpreted and native, and both must give the
  same value or the same error.
  """

  # the backend is switched on through the application env
  use ExUnit.Case, async: false

  alias Compos.Scheme
  alias Compos.Scheme.Eval

  setup do
    prev = Application.get_env(:compos_scheme, :native, :off)
    on_exit(fn -> Application.put_env(:compos_scheme, :native, prev) end)
  end

  defp run(mode, src) do
    Application.put_env(:compos_scheme, :native, mode)

    try do
      case Scheme.eval_string(Scheme.new(), src) do
        {:ok, value, _} -> {:ok, Scheme.print(value)}
        {:error, message} -> {:error, message}
      end
    after
      Application.put_env(:compos_scheme, :native, :off)
    end
  end

  @programs [
    "(define (f x) (* x 2)) (f 21)",
    "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 20)",
    "(define (loop i acc) (if (= i 0) acc (loop (- i 1) (+ acc i)))) (loop 100000 0)",
    "(define (f n) (let loop ((i 0) (acc '())) (if (= i n) (reverse acc) (loop (+ i 1) (cons i acc))))) (f 10)",
    "(define (adder n) (lambda (x) (+ x n))) ((adder 3) 4)",
    "(define (compose f g) (lambda (x) (f (g x)))) ((compose (lambda (x) (* x 2)) (lambda (x) (+ x 1))) 5)",
    "(define (f x) (let ((a 1) (b 2)) (let* ((c (+ a b)) (d (* c x))) (list a b c d)))) (f 10)",
    "(define (f x) (cond ((< x 0) 'neg) ((= x 0) 'zero) (else 'pos))) (list (f -1) (f 0) (f 5))",
    "(define (f x) (cond ((assq x '((a . 1) (b . 2)))) (else 'none))) (list (f 'a) (f 'z))",
    "(define (f x) (and (> x 0) (< x 10) x)) (list (f 5) (f 50) (f -1))",
    "(define (f x) (or (and (> x 5) 'big) (and (> x 0) 'small) 'none)) (list (f 9) (f 2) (f -2))",
    "(define (f x) (when (> x 0) 'yes)) (define (g x) (unless (> x 0) 'no)) (list (f 1) (f -1) (g 1) (g -1))",
    "(define (f . xs) xs) (list (f) (f 1 2 3))",
    "(define (f a &optional b c) (list a b c)) (list (f 1) (f 1 2) (f 1 2 3))",
    "(define (f a &rest r) (list a r)) (f 1 2 3)",
    "(define (f a b) a) (f 1)",
    "(define (f a) a) (f 1 2)",
    "(define (f a &optional b) a) (f 1 2 3)",
    "(define (f) (undefined-thing 1)) (f)",
    "(define (f) (car '())) (f)",
    "(define counter 0) (define (bump!) (set! counter (+ counter 1)) counter) (bump!) (bump!)",
    "(define (f) (begin 1 2 3)) (f)",
    "(define (f x) (if x 'yes)) (list (f #t) (f #f))",
    "(define (f) \"str\") (f)",
    "(define (f xs) (map (lambda (x) (* x x)) xs)) (f '(1 2 3))",
    "(define (f xs) (filter (lambda (x) (> x 1)) xs)) (f '(1 2 3))",
    "(define (f) (let loop ((i 0)) (if (< i 3) (begin (loop (+ i 1))) i))) (f)",
    "(define (f) (let loop ((i 0)) (if (< i 3) (loop (+ i 1) 9) i))) (f)",
    "(define (f n) (let loop ((loop n)) loop)) (f 7)",
    "(define (mk) (let loop ((i 0)) (if (= i 2) loop (loop (+ i 1))))) (procedure? (mk))",
    "(define (f x) (let ((x (+ x 1))) (let ((x (* x 2))) x))) (f 1)",
    "(define (f) (define y 2) y) (f)",
    "(define (f x) (set! x 3) x) (f 1)",
    "(let loop ((i 0) (acc 0)) (if (= i 1000) acc (loop (+ i 1) (+ acc i))))",
    "(define (f) (if)) (f)",
    "(define (f x) (cond (x))) (list (f 3) (f #f))",
    "(define (f) (and)) (define (g) (or)) (list (f) (g))",
    "(define (sum n) (if (= n 0) 0 (+ n (sum (- n 1))))) (sum 20000)",
    "(define (runaway n) (+ 1 (runaway n))) (runaway 1)",
    "(define (f) (lambda args args)) ((f) 1 2)",
    "(define g 1) (define (f) g) (define g 2) (f)",
    "(define (f) '(a \"b\" 1.5 #t)) (f)",
    # the inlined core builtins, on the arguments their guards take and refuse
    "(define (f a b) (list (+ a b) (- a b) (- a) (* a b) (= a b) (< a b) (> a b) (<= a b) (>= a b))) (list (f 2 3) (f 2.0 2) (f -1 -1.5))",
    "(define (f a b) (list (eq? a b) (eqv? a b) (equal? a b) (not a) (null? a) (pair? a) (zero? a))) (list (f 2 2.0) (f '() '()) (f '(1) '(1)) (f #f 0) (f 0.0 0))",
    "(define (f x) (list (number? x) (integer? x) (string? x) (symbol? x) (pair? x))) (list (f 1) (f 1.5) (f \"s\") (f 'a) (f '(1 . 2)))",
    "(define (f x) (list (car x) (cdr x) (cons x x) (list) (list x x x))) (f '(1 . 2))",
    "(define (f x) (+ x 1)) (f \"a\")",
    "(define (f x) (- x)) (f 'a)",
    "(define (f x) (car x)) (f 5)",
    "(define (f x) (cdr x)) (f '())",
    "(define (f) (car)) (f)",
    "(define (f a b c) (+ a b c)) (f 1 2 3)",
    "(define (f x) (car x)) (define (car x) 'mine) (f '(1))",
    "(define (f x) (let ((car cdr)) (car x))) (f '(1 2))"
  ]

  for {src, i} <- Enum.with_index(@programs) do
    test "program #{i} answers as the interpreter does: #{String.slice(src, 0, 60)}" do
      src = unquote(src)
      assert run(:always, src) == run(:off, src)
    end
  end

  test "a top-level lexical lambda is native when the backend is on" do
    Application.put_env(:compos_scheme, :native, :always)
    {:ok, f, _} = Scheme.eval_string(Scheme.new(), "(define (f x) (lambda (y) (+ x y))) f")
    assert {:closure, _, {:ncode, fun, source}, _} = f
    assert is_function(fun, 2)
    assert Eval.source({:ncode, fun, source}) == source
  end

  test "function-source reads a native closure" do
    Application.put_env(:compos_scheme, :native, :always)
    {:ok, src, _} = Scheme.eval_string(Scheme.new(), "(define (f x) (+ x 1)) (function-source f)")
    assert Scheme.print(src) =~ "(+ x 1)"
  end

  test "packages mode compiles only inside with_native" do
    Application.put_env(:compos_scheme, :native, :packages)
    {:ok, plain, _} = Scheme.eval_string(Scheme.new(), "(lambda (x) x)")
    {:ok, native, _} = Compos.Scheme.Native.with_native(fn -> Scheme.eval_string(Scheme.new(), "(lambda (x) x)") end)
    assert {:closure, _, {:lcode, _, _, _}, _} = plain
    assert {:closure, _, {:ncode, _, _}, _} = native
  end

  test "the call gate refuses a name read by native code" do
    Application.put_env(:compos_scheme, :native, :always)
    {:ok, _, interp} = Scheme.eval_string(Scheme.new(), "(define (secret) 1) (define (f) (secret))")
    gate = Eval.call_gate([["secret", "needs permission"]], [])
    assert {:error, msg} = Eval.with_call_gate(gate, fn -> Scheme.eval_string(interp, "(f)") end)
    assert msg =~ "needs permission"
    trusted = Eval.call_gate([["secret", "needs permission"]], ["f"])
    assert {:ok, 1, _} = Eval.with_call_gate(trusted, fn -> Scheme.eval_string(interp, "(f)") end)
  end

  test "a redefinition takes effect for native callers" do
    Application.put_env(:compos_scheme, :native, :always)
    {:ok, _, interp} = Scheme.eval_string(Scheme.new(), "(define (g) 1) (define (f) (g))")
    {:ok, 1, interp} = Scheme.eval_string(interp, "(f)")
    {:ok, 2, _} = Scheme.eval_string(interp, "(define (g) 2) (f)")
  end

  test "an inlined builtin takes a redefinition made after the compile" do
    Application.put_env(:compos_scheme, :native, :always)
    {:ok, _, interp} = Scheme.eval_string(Scheme.new(), "(define (f x) (car x))")
    {:ok, 1, interp} = Scheme.eval_string(interp, "(f '(1 2))")
    {:ok, _, interp} = Scheme.eval_string(interp, "(define (car x) 'mine)")
    assert {:ok, {:sym, "mine"}, _} = Scheme.eval_string(interp, "(f '(1 2))")
  end

  describe "a file's native closures keep their place, not their source" do
    setup do
      dir = Path.join(System.tmp_dir!(), "native-src-\#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:compos_scheme, :native, :always)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{path: Path.join(dir, "lib.scm")}
    end

    @lib """
    ; a comment, then a string over two lines with a paren in it
    (define greeting "a (
    b") (define n 1)

    (define (outer x)
      (let ((k (lambda (y) (+ x y))))
        (k 1)))

    (define (twice f) (lambda (v) (f (f v))))
    """

    test "function-source reads the body from the file", %{path: path} do
      File.write!(path, @lib)
      {:ok, _, interp} = Scheme.eval_string(Scheme.new(), @lib, path)
      {:ok, f, interp} = Scheme.eval_string(interp, "outer")
      assert {:closure, _, {:ncode, _, {:at, ^path, 5, 7, 0, 0, _}}, _} = f
      {:ok, src, interp} = Scheme.eval_string(interp, "(function-source outer)")
      assert Scheme.print(src) =~ "(lambda (x) (let ((k (lambda (y) (+ x y)))) (k 1)))"

      # an inner closure finds its own body inside the outer one
      {:ok, src, _} = Scheme.eval_string(interp, "(function-source (twice car))")
      assert src == "(lambda (v) (f (f v)))"
    end

    test "a file changed since the load answers a note, not the wrong source", %{path: path} do
      File.write!(path, @lib)
      {:ok, _, interp} = Scheme.eval_string(Scheme.new(), @lib, path)
      File.write!(path, String.replace(@lib, "(k 1)", "(k 2)"))
      {:ok, src, _} = Scheme.eval_string(interp, "(function-source outer)")
      assert Scheme.print(src) =~ "changed since it loaded"
    end

    test "the reader's spans match its forms" do
      assert [{_, 2, 3}, {_, 3, 3}, {_, 5, 7}, {_, 9, 9}] = Compos.Scheme.Reader.read_all_lines(@lib)
    end
  end

  test "a native closure's captured frames survive the GC" do
    Application.put_env(:compos_scheme, :native, :always)

    {:ok, _, interp} =
      Scheme.eval_string(Scheme.new(), """
      (define (mk) (let ((secret 41)) (let ((v (list secret))) (lambda () (+ 1 (car v))))))
      (define kept (let ((tmp 1)) (define inner (lambda () tmp)) (let ((c (mk))) (lambda () (+ (c) (inner))))))
      """)

    _ = Scheme.gc(interp, [])
    assert {:ok, 43, _} = Scheme.eval_string(interp, "(kept)")
  end

  @tag :bench
  test "benchmark: native against interpreted" do
    src = """
    (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
    (define (count n) (let loop ((i 0) (acc 0)) (if (= i n) acc (loop (+ i 1) (+ acc i)))))
    (define (squares xs) (map (lambda (x) (* x x)) xs))
    (define (build n) (let loop ((i 0) (acc '())) (if (= i n) acc (loop (+ i 1) (cons i acc)))))
    """

    time = fn mode ->
      Application.put_env(:compos_scheme, :native, mode)
      {:ok, _, interp} = Scheme.eval_string(Scheme.new(), src)
      Application.put_env(:compos_scheme, :native, :off)

      for prog <- ["(fib 22)", "(count 300000)", "(length (squares (build 100000)))"] do
        {us, {:ok, v, _}} = :timer.tc(fn -> Scheme.eval_string(interp, prog) end)
        {prog, div(us, 1000), v}
      end
    end

    off = time.(:off)
    on = time.(:always)
    IO.puts("\nnative bench (ms): " <> inspect(Enum.zip(off, on) |> Enum.map(fn {{p, a, v}, {_, b, v}} -> {p, a, b} end)))
  end
end
