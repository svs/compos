defmodule Compos.Scheme.Builtins do
  alias Compos.Scheme.Prim
  import Bitwise

  alias Compos.Scheme.Text

  @moduledoc """
  Core builtins. Higher-order library functions (map/filter/etc.) live in the
  Scheme prelude instead — they need `apply`, which the prelude gets for free.
  """

  alias Compos.Scheme.{Eval, Printer}

  # :calendar.datetime_to_gregorian_seconds at the unix epoch
  @unix_epoch_gregorian 62_167_219_200

  def all, do: Prim.funs(entries())

  @doc "NAME => doc for every builtin."
  def docs, do: Prim.docs(entries())

  @doc "Every builtin under its {name, doc} key."
  def entries do
    %{
      {"+", "(+ N ...) — return the sum of the numbers; 0 with no arguments."} =>
        &arith(&1, 0, fn a, b -> a + b end),
      {"*", "(* N ...) — return the product of the numbers; 1 with no arguments."} =>
        &arith(&1, 1, fn a, b -> a * b end),
      {"-", "(- N ...) — negate N, or subtract the other numbers from N in order."} => &sub/1,
      {"/", "(/ N ...) — divide N by the other numbers in order; return a float."} => &divide/1,
      {"=", "(= N ...) — return true if each number equals the next."} =>
        cmp(fn a, b -> a == b end),
      {"<", "(< N ...) — return true if each number is less than the next."} =>
        cmp(fn a, b -> a < b end),
      {">", "(> N ...) — return true if each number is greater than the next."} =>
        cmp(fn a, b -> a > b end),
      {"<=", "(<= N ...) — return true if each number is less than or equal to the next."} =>
        cmp(fn a, b -> a <= b end),
      {">=", "(>= N ...) — return true if each number is greater than or equal to the next."} =>
        cmp(fn a, b -> a >= b end),
      {"equal?", "(equal? A B) — return true if A and B are structurally equal."} => fn [a, b] ->
        a == b
      end,
      # Values are BEAM terms and a pair is never mutated in place, so there is
      # no identity to compare: eq? and eqv? are exact equality. They differ from
      # equal? on numbers only: (eqv? 2 2.0) is false, as in Scheme.
      {"eq?", "(eq? A B) — return true if A and B are the same value: equal, with 2 and 2.0 kept apart."} =>
        fn [a, b] -> a === b end,
      {"eqv?", "(eqv? A B) — return true if A and B are the same value, as eq? does."} =>
        fn [a, b] -> a === b end,
      {"not", "(not X) — return true if X is false."} => fn [a] -> a == false end,
      {"modulo", "(modulo A B) — return A modulo B; the result takes the sign of B."} => fn [a, b] ->
        Integer.mod(a, b)
      end,
      {"remainder",
       "(remainder A B) — return the remainder of A/B; the result takes the sign of A."} => fn [
                                                                                                 a,
                                                                                                 b
                                                                                               ] ->
        rem(a, b)
      end,
      {"quotient", "(quotient A B) — return the integer quotient of A/B, truncated toward zero."} =>
        fn [a, b] -> div(a, b) end,
      {"min", "(min N ...) — return the smallest of the numbers."} => fn args ->
        Enum.min(args)
      end,
      {"max", "(max N ...) — return the largest of the numbers."} => fn args -> Enum.max(args) end,
      {"abs", "(abs N) — return the absolute value of N."} => fn [x] -> abs(x) end,
      # Math is Erlang's :math. floor, ceiling, round and truncate answer
      # integers, as they do in Emacs Lisp.
      {"floor", "(floor N [DIVISOR]) — return the largest integer not above N, or N/DIVISOR."} =>
        &floor_div/1,
      {"ceiling", "(ceiling N) — return the smallest integer not below N."} => fn [x] ->
        ceil(x)
      end,
      {"round", "(round N) — return the nearest integer to N; a half rounds away from zero."} =>
        fn [x] -> round(x) end,
      {"truncate", "(truncate N) — return N without its fraction, as an integer."} => fn [x] ->
        trunc(x)
      end,
      {"float", "(float N) — return N as a float."} => fn [x] -> x * 1.0 end,
      {"integer?", "(integer? X) — return true if X is an integer."} => fn [x] ->
        is_integer(x)
      end,
      {"float?", "(float? X) — return true if X is a float."} => fn [x] -> is_float(x) end,
      {"zero?", "(zero? N) — return true if N is 0 or 0.0."} => fn [x] -> x == 0 end,
      {"sqrt", "(sqrt N) — return the square root of N, a float."} => fn [x] ->
        :math.sqrt(x)
      end,
      {"expt",
       "(expt BASE POWER) — return BASE to POWER; an integer when both are integers and POWER is not negative."} =>
        &expt/1,
      {"exp", "(exp N) — return e to the power N."} => fn [x] -> :math.exp(x) end,
      {"log", "(log N [BASE]) — return the logarithm of N, natural or in BASE."} => &log/1,
      {"sin", "(sin N) — return the sine of N radians."} => fn [x] -> :math.sin(x) end,
      {"cos", "(cos N) — return the cosine of N radians."} => fn [x] -> :math.cos(x) end,
      {"tan", "(tan N) — return the tangent of N radians."} => fn [x] -> :math.tan(x) end,
      {"asin", "(asin N) — return the arc sine of N, in radians."} => fn [x] -> :math.asin(x) end,
      {"acos", "(acos N) — return the arc cosine of N, in radians."} => fn [x] ->
        :math.acos(x)
      end,
      {"atan", "(atan Y [X]) — return the arc tangent of Y, or of Y/X in the right quadrant."} =>
        &atan/1,
      {"float-pi", "(float-pi) — return pi."} => fn [] -> :math.pi() end,
      {"member", "(member X LST) — return the tail of LST from the first X, or false."} => fn [
                                                                                                x,
                                                                                                l
                                                                                              ] ->
        case Enum.drop_while(l, &(&1 != x)) do
          [] -> false
          tail -> tail
        end
      end,
      {"sort", "(sort LST) — return LST sorted in ascending term order."} => fn [l] ->
        Enum.sort(l)
      end,
      {"cons", "(cons H T) — prepend H to the list T; T must be a list."} => fn [h, t]
                                                                                when is_list(t) ->
        [h | t]
      end,
      {"car", "(car LST) — return the first element of LST."} => fn [[h | _]] -> h end,
      {"cdr", "(cdr LST) — return LST without its first element."} => fn [[_ | t]] -> t end,
      {"list", "(list X ...) — return a list of the arguments."} => fn args -> args end,
      {"null?", "(null? X) — return true if X is the empty list."} => fn [x] -> x == [] end,
      {"pair?", "(pair? X) — return true if X is a non-empty list."} => fn [x] ->
        is_list(x) and x != []
      end,
      {"length", "(length LST) — return the number of elements in LST."} => fn [l] ->
        length(l)
      end,
      {"append", "(append LST ...) — concatenate the lists into one list."} => fn lists ->
        Enum.concat(lists)
      end,
      {"reverse", "(reverse LST) — return LST with its elements in reverse order."} => fn [l] ->
        Enum.reverse(l)
      end,
      {"number?", "(number? X) — return true if X is a number."} => fn [x] -> is_number(x) end,
      {"string?", "(string? X) — return true if X is a string."} => fn [x] -> is_binary(x) end,
      {"symbol?", "(symbol? X) — return true if X is a symbol."} => fn [x] ->
        match?({:sym, _}, x)
      end,
      {"procedure?",
       "(procedure? X) — return true if X is a callable, including an advised function."} => fn [
                                                                                                  x
                                                                                                ] ->
        match?({:closure, _, _, _}, x) or match?({:builtin, _, _}, x) or
          match?({:interposed, _, _}, x)
      end,
      # introspection: closures carry their AST, so userland functions can
      # print their own source; builtins are opaque Elixir
      {"function-source",
       "(function-source F) — return the lambda source of F; builtins report as opaque."} => fn [
                                                                                                  v
                                                                                                ] ->
        case source_callable(v) do
          {:closure, {req, opt, rest}, body, _env} ->
            params =
              req ++
                if(opt == [], do: [], else: ["&optional" | opt]) ++
                if(rest, do: ["&rest", rest], else: [])

            Compos.Scheme.Printer.print([
              {:sym, "lambda"},
              Enum.map(params, &{:sym, &1}) | body
            ])

          {:builtin, name, _} ->
            "#<builtin #{name} — implemented in Elixir, no Scheme source>"

          other ->
            Compos.Scheme.Printer.print(other)
        end
      end,
      {"string-append", "(string-append S ...) — concatenate the strings into one string."} =>
        fn args -> Enum.join(args) end,
      {"string-length", "(string-length S) — return the count of characters in S, not bytes."} =>
        fn [s] -> String.length(s) end,
      {"string=?", "(string=? S ...) — return true if every string is the same."} => fn [a | rest]
                                                                                        when is_binary(
                                                                                               a
                                                                                             ) ->
        Enum.all?(rest, &(&1 == a))
      end,
      # every Scheme has format and this one did not, so a caller building a
      # message reached for string-append and value->string, or guessed a name
      # that is not here and lost the guess inside a callback
      {"format",
       "(format FMT ARG ...) — build a string: ~a inserts a value as text, ~s as its printed form, ~% a newline, ~~ a tilde."} =>
        fn [fmt | args] when is_binary(fmt) -> format_string(fmt, args) end,
      {"string-contains?", "(string-contains? S SUB) — return true if S contains SUB."} => fn [
                                                                                                s,
                                                                                                sub
                                                                                              ] ->
        String.contains?(s, sub)
      end,
      {"string-prefix?", "(string-prefix? PRE S) — return true if S starts with PRE."} => fn [
                                                                                               pre,
                                                                                               s
                                                                                             ] ->
        String.starts_with?(s, pre)
      end,
      {"string-replace",
       "(string-replace S FROM TO) — S with every FROM replaced by TO; a non-string S is \"\"."} =>
        fn
          [s, from, to] when is_binary(s) -> String.replace(s, from, to)
          [_, _, _] -> ""
        end,
      {"html-escape",
       "(html-escape S) — S with & < > \" and ' as HTML entities; a non-string S is \"\"."} => fn
        [s] when is_binary(s) ->
          s
          |> String.replace("&", "&amp;")
          |> String.replace("<", "&lt;")
          |> String.replace(">", "&gt;")
          |> String.replace("\"", "&quot;")
          |> String.replace("'", "&#39;")

        [_] ->
          ""
      end,
      {"first-line", "(first-line S) — the first line of S, trimmed; a non-string S is \"\"."} =>
        fn
          [s] when is_binary(s) -> s |> String.split("\n", parts: 2) |> hd() |> String.trim()
          [_] -> ""
        end,
      {"file-name-nondirectory",
       "(file-name-nondirectory PATH) — the last segment of PATH; \"\" after a trailing slash."} =>
        fn [path] -> path |> String.split("/") |> List.last() end,
      {"string-suffix?", "(string-suffix? SUF S) — return true if S ends with SUF."} => fn [
                                                                                             suf,
                                                                                             s
                                                                                           ] ->
        String.ends_with?(s, suf)
      end,
      # Levenshtein distance. The did-you-mean suggestions rank every
      # public-api name per unbound error; an interpreted inner loop held
      # the UI lane for seconds, so the distance is a builtin.
      {"string-edit-distance",
       "(string-edit-distance A B) — the Levenshtein distance between two strings."} => fn [a, b] ->
        bl = String.to_charlist(b)

        a
        |> String.to_charlist()
        |> Enum.reduce(Enum.to_list(0..length(bl)), fn ca, prev_row ->
          first = hd(prev_row) + 1

          {row_rev, _diag} =
            bl
            |> Enum.zip(tl(prev_row))
            |> Enum.reduce({[first], hd(prev_row)}, fn {cb, above}, {acc, diag} ->
              cost = if ca == cb, do: 0, else: 1
              {[min(min(hd(acc) + 1, above + 1), diag + cost) | acc], above}
            end)

          Enum.reverse(row_rev)
        end)
        |> List.last()
      end,
      {"string-rindex",
       "(string-rindex S SUB) — return the byte offset of the last SUB in S, or false."} => fn [
                                                                                                 s,
                                                                                                 sub
                                                                                               ] ->
        case :binary.matches(s, sub) do
          [] -> false
          matches -> matches |> List.last() |> elem(0)
        end
      end,
      {"common-prefix",
       "(common-prefix STRINGS) — return the longest common prefix of the list of strings."} =>
        fn [strings] ->
          case strings do
            [] ->
              ""

            [first | rest] ->
              Enum.reduce(rest, first, fn s, acc ->
                acc
                |> String.graphemes()
                |> Enum.zip(String.graphemes(s))
                |> Enum.take_while(fn {a, b} -> a == b end)
                |> Enum.map_join(&elem(&1, 0))
              end)
          end
        end,
      {"string-index",
       "(string-index S SUB [START]) — return the byte offset of the first SUB in S at or after START, or false."} =>
        fn
          [s, sub] ->
            case :binary.match(s, sub) do
              :nomatch -> false
              {pos, _len} -> pos
            end

          # a caller that walks every occurrence needs to resume after the
          # last one, so it says where to start
          [s, sub, from] when from >= 0 and from <= byte_size(s) ->
            case :binary.match(s, sub, scope: {from, byte_size(s) - from}) do
              :nomatch -> false
              {pos, _len} -> pos
            end

          [_s, _sub, _from] ->
            false
        end,
      {"string-upcase", "(string-upcase S) — return S converted to upper case."} => fn [s] ->
        String.upcase(s)
      end,
      {"string-downcase", "(string-downcase S) — return S converted to lower case."} => fn [s] ->
        String.downcase(s)
      end,
      {"string-trim", "(string-trim S) — return S without leading and trailing whitespace."} =>
        fn [s] -> String.trim(s) end,
      {"string-repeat", "(string-repeat S N) — return S repeated N times."} => fn [s, n] ->
        String.duplicate(s, n)
      end,
      # byte-offset variants: compose with point/overlay/search positions,
      # which are all byte-based (grapheme substring/string-length are not)
      {"string-byte-length", "(string-byte-length S) — return the length of S in bytes."} => fn [
                                                                                                  s
                                                                                                ] ->
        byte_size(s)
      end,
      {"substring-bytes",
       "(substring-bytes S FROM TO) — return the byte range FROM..TO, snapped to codepoint boundaries."} =>
        fn [s, from, to] ->
          if from < 0 or to < from or to > byte_size(s) do
            raise Eval.Error,
              message: "substring-bytes: range #{from}..#{to} out of 0..#{byte_size(s)}"
          end

          # snap both ends down to codepoint boundaries (Text says why)
          Text.slice(s, from, to)
        end,
      # reading and writing single bytes: a binary protocol arrives as
      # bytes, and Scheme has no character type to decode them with. These
      # are the accessors a length prefix or a message tag needs.
      {"string-byte",
       "(string-byte S I) — return byte I of S as an integer 0..255, or #f past the end."} => fn [
                                                                                                   s,
                                                                                                   i
                                                                                                 ] ->
        if i < 0 or i >= byte_size(s) do
          false
        else
          :binary.at(s, i)
        end
      end,
      {"string-bytes",
       "(string-bytes S [FROM TO]) — return the bytes of S, or of a byte range, as integers."} =>
        fn
          [s] -> :binary.bin_to_list(s)
          [s, from, to] -> bytes_range(s, from, to)
        end,
      {"bytes->string", "(bytes->string BYTES) — build a string from a list of integers 0..255."} =>
        fn [bytes] ->
          Enum.each(bytes, fn b ->
            unless is_integer(b) and b >= 0 and b <= 255 do
              raise Eval.Error, message: "bytes->string: #{inspect(b)} is not a byte"
            end
          end)

          :binary.list_to_bin(bytes)
        end,
      # An unsigned integer out of a byte range, and back. Big-endian by
      # default: every network protocol writes its lengths that way.
      {"bytes->integer",
       "(bytes->integer S FROM WIDTH [ENDIAN]) — read an unsigned integer of WIDTH bytes at FROM; ENDIAN is \"big\" (default) or \"little\"."} =>
        fn
          [s, from, width] -> decode_int(s, from, width, "big")
          [s, from, width, endian] -> decode_int(s, from, width, endian)
        end,
      {"integer->bytes",
       "(integer->bytes N WIDTH [ENDIAN]) — write N as WIDTH bytes; ENDIAN is \"big\" (default) or \"little\"."} =>
        fn
          [n, width] -> encode_int(n, width, "big")
          [n, width, endian] -> encode_int(n, width, endian)
        end,
      # binary-safe transport encoding (MCP proxy, anything crossing RPC
      # where printed-string escaping would be ambiguous)
      {"base64-encode", "(base64-encode S) — return S encoded as base64."} => fn [s] ->
        Base.encode64(s)
      end,
      # a file read gives raw bytes; text consumers must refuse a binary
      {"string-valid-utf8?", "(string-valid-utf8? S) — return #t if S is valid UTF-8 text."} =>
        fn [s] -> is_binary(s) and String.valid?(s) end,
      {"base64-decode", "(base64-decode S) — decode the base64 string S; error on invalid input."} =>
        fn [s] ->
          case Base.decode64(s) do
            {:ok, v} -> v
            :error -> raise Eval.Error, message: "base64-decode: invalid input"
          end
        end,
      {"string-split", "(string-split S SEP) — split S on the separator SEP into a list."} => fn [
                                                                                                   s,
                                                                                                   sep
                                                                                                 ] ->
        String.split(s, sep)
      end,
      {"string-join",
       "(string-join PARTS SEP) — join the list PARTS into one string with SEP between."} => fn [
                                                                                                  parts,
                                                                                                  sep
                                                                                                ] ->
        Enum.join(parts, sep)
      end,
      {"string-pad-left", "(string-pad-left S N) — pad S with leading spaces to N characters."} =>
        fn [s, n] -> String.pad_leading(s, n) end,
      {"string-pad-right", "(string-pad-right S N) — pad S with trailing spaces to N characters."} =>
        fn [s, n] -> String.pad_trailing(s, n) end,
      {"substring",
       "(substring S FROM TO) — return the character range FROM..TO of S, not bytes."} => fn [
                                                                                               s,
                                                                                               from,
                                                                                               to
                                                                                             ] ->
        String.slice(s, from, to - from)
      end,
      {"number->string", "(number->string N) — return N printed as a string."} => fn [n] ->
        Printer.print(n)
      end,
      {"value->string", "(value->string V) — return V printed as a string."} => fn [v] ->
        Printer.print(v)
      end,
      {"string->number", "(string->number S) — parse S as an integer or a float."} => fn [s] ->
        case Integer.parse(s) do
          {i, ""} -> i
          _ -> with {f, ""} <- Float.parse(s), do: f
        end
      end,
      {"symbol->string", "(symbol->string SYM) — return the name of SYM as a string."} => fn [
                                                                                               {:sym,
                                                                                                s}
                                                                                             ] ->
        s
      end,
      {"string->symbol", "(string->symbol S) — return the symbol with the name S."} => fn [s] ->
        {:sym, s}
      end,
      {"apply", "(apply F ARGS) — call F with the elements of the list ARGS as arguments."} =>
        fn [f, args], store -> Eval.apply_fn(f, args, store) end,
      # List traversal applies a Scheme callable per element and threads the
      # store through. The interpreted loops these replace paid one frame
      # and a dozen evals per element, and a catalog walk at load time ran
      # into the millions of frames.
      {"map", "(map F LST) — return the list of F applied to each element of LST."} => fn [f, l],
                                                                                          store
                                                                                          when is_list(
                                                                                                 l
                                                                                               ) ->
        Enum.map_reduce(l, store, fn x, store -> Eval.apply_fn(f, [x], store) end)
      end,
      {"for-each", "(for-each F LST) — call F on each element of LST in order; return true."} =>
        fn [f, l], store when is_list(l) ->
          store =
            Enum.reduce(l, store, fn x, store ->
              {_, store} = Eval.apply_fn(f, [x], store)
              store
            end)

          {true, store}
        end,
      {"filter", "(filter PRED LST) — return the elements of LST for which PRED is true."} => fn [
                                                                                                   pred,
                                                                                                   l
                                                                                                 ],
                                                                                                 store
                                                                                                 when is_list(
                                                                                                        l
                                                                                                      ) ->
        select(pred, l, store, true)
      end,
      {"remove", "(remove PRED LST) — return the elements of LST for which PRED is false."} =>
        fn [pred, l], store when is_list(l) -> select(pred, l, store, false) end,
      {"fold", "(fold F ACC LST) — reduce LST from the left with (F ACC X), starting from ACC."} =>
        fn [f, acc, l], store when is_list(l) ->
          Enum.reduce(l, {acc, store}, fn x, {acc, store} -> Eval.apply_fn(f, [acc, x], store) end)
        end,
      {"assoc",
       "(assoc KEY ALIST) — return the first element of ALIST whose car equals KEY, or false."} =>
        fn [key, l] when is_list(l) ->
          Enum.find(l, false, fn
            [k | _] -> k == key
            _ -> false
          end)
        end,
      # a non-list (#f from a missing lookup) answers #f, so a caller never
      # guards it: 25 packages wrote that guard when this raised
      {"plist-get",
       "(plist-get PLIST KEY) — return the value after KEY in the flat PLIST; false when KEY is absent or PLIST is not a list."} =>
        fn [pl, key] -> plist_get(pl, key) end,
      {"sh-quote",
       "(sh-quote STRING) — STRING as one shell word in single quotes, safe for any character."} =>
        fn [s] when is_binary(s) -> "'" <> String.replace(s, "'", "'\\''") <> "'" end,
      {"plist-put",
       "(plist-put PLIST KEY VAL) — PLIST with KEY VAL first and any older KEY pair gone."} =>
        fn [pl, key, val] -> [key, val | plist_delete(pl, key)] end,
      # native: an interpreted walk paid one frame per element, and a read
      # into a list of 3000 lines per definition made an outline take seconds
      {"list-ref",
       "(list-ref LST I) — return the element of LST at the 0-based index I; an error past the end."} =>
        fn [l, i] when is_list(l) and is_integer(i) ->
          case Enum.at(l, i, :none) do
            :none -> raise Eval.Error, message: "list-ref: index #{i} out of 0..#{length(l) - 1}"
            v -> v
          end
        end,
      {"take", "(take LST N) — the first N elements of LST, or all of them when it is shorter."} =>
        fn [l, n] when is_list(l) and is_integer(n) -> Enum.take(l, max(n, 0)) end,
      {"alist-put",
       "(alist-put ALIST KEY VAL) — ALIST with (KEY VAL) first and any older KEY entry gone."} =>
        fn [al, key, val] when is_list(al) ->
          [[key, val] | Enum.reject(al, &match?([^key | _], &1))]
        end,
      {"alist-get", "(alist-get ALIST KEY) — the value after KEY in ALIST, or #f."} => fn [
                                                                                            al,
                                                                                            key
                                                                                          ]
                                                                                          when is_list(
                                                                                                 al
                                                                                               ) ->
        case Enum.find(al, &match?([^key | _], &1)) do
          [_, v | _] -> v
          _ -> false
        end
      end,
      {"alist-delete", "(alist-delete ALIST KEY) — ALIST without its KEY entry."} => fn [al, key]
                                                                                        when is_list(
                                                                                               al
                                                                                             ) ->
        Enum.reject(al, &match?([^key | _], &1))
      end,
      {"list-head",
       "(list-head LST K) — return the first K elements of LST; an error past the end."} => fn [
                                                                                                 l,
                                                                                                 k
                                                                                               ]
                                                                                               when is_list(
                                                                                                      l
                                                                                                    ) and
                                                                                                      is_integer(
                                                                                                        k
                                                                                                      ) ->
        if k < 0 or k > length(l) do
          raise Eval.Error, message: "list-head: count #{k} out of 0..#{length(l)}"
        end

        Enum.take(l, k)
      end,
      {"list-tail",
       "(list-tail LST K) — return LST without its first K elements; an error past the end."} =>
        fn [l, k] when is_list(l) and is_integer(k) ->
          if k < 0 or k > length(l) do
            raise Eval.Error, message: "list-tail: count #{k} out of 0..#{length(l)}"
          end

          Enum.drop(l, k)
        end,
      {"display", "(display X) — write X to standard output without quotes."} => fn [x] ->
        IO.write(Printer.display(x))
        :void
      end,
      {"newline", "(newline) — write a newline to standard output."} => fn [] ->
        IO.write("\n")
        :void
      end,
      {"error",
       "(error X ...) — raise an error; the message joins the displayed arguments with spaces."} =>
        fn args ->
          raise Eval.Error, message: Enum.map_join(args, " ", &Printer.display/1)
        end,
      {"re-match?", "(re-match? PAT S) — return true if the regex PAT matches S."} => fn [pat, s] ->
        Regex.match?(re!(pat), s)
      end,
      {"re-match",
       "(re-match PAT S) — return the matched strings (match, then groups), or false."} => fn [
                                                                                                pat,
                                                                                                s
                                                                                              ] ->
        case Regex.run(re!(pat), s) do
          nil -> false
          groups -> groups
        end
      end,
      {"re-find",
       "(re-find PAT S START) — return [START END] byte offsets of the first match, or false."} =>
        fn [pat, s, start] ->
          case Regex.run(re!(pat), s, return: :index, offset: start) do
            nil -> false
            [{ms, len} | _] -> [ms, ms + len]
          end
        end,
      {"re-find*",
       "(re-find* PAT S) — return [START END] byte offsets for every match of PAT in S."} => fn [
                                                                                                  pat,
                                                                                                  s
                                                                                                ] ->
        re!(pat)
        |> Regex.scan(s, return: :index)
        |> Enum.map(fn [{ms, len} | _] -> [ms, ms + len] end)
      end,
      {"re-groups",
       "(re-groups PAT S START) — return [START END] byte pairs per group; false for unmatched groups."} =>
        fn [pat, s, start] ->
          # PCRE truncates trailing unmatched groups; wrapping the pattern
          # with a final always-matching () forces every group to report
          # ({-1,0} for non-participants), then we drop the sentinel
          case Regex.run(re!("(?:" <> pat <> ")()"), s, return: :index, offset: start) do
            nil ->
              false

            groups ->
              groups
              |> Enum.drop(-1)
              |> Enum.map(fn
                {-1, 0} -> false
                {gs, len} -> [gs, gs + len]
              end)
          end
        end,
      {"re-replace", "(re-replace PAT S REPL) — replace the first match of PAT in S with REPL."} =>
        fn [pat, s, repl] -> Regex.replace(re!(pat), s, repl, global: false) end,
      {"re-replace-all",
       "(re-replace-all PAT S REPL) — replace every match of PAT in S with REPL."} => fn [
                                                                                           pat,
                                                                                           s,
                                                                                           repl
                                                                                         ] ->
        Regex.replace(re!(pat), s, repl)
      end,
      {"current-time", "(current-time) — return the current time as unix seconds."} => fn [] ->
        System.os_time(:second)
      end,
      {"monotonic-ms",
       "(monotonic-ms) — return a monotonic millisecond count, for timing one span."} => fn [] ->
        System.monotonic_time(:millisecond)
      end,
      {"time->parts",
       "(time->parts SECS) — return local [YEAR MONTH DAY HOUR MINUTE WEEKDAY]; Monday is 1."} =>
        fn [secs] ->
          {{y, mo, d}, {h, mi, _s}} = :calendar.system_time_to_local_time(trunc(secs), :second)
          [y, mo, d, h, mi, :calendar.day_of_the_week({y, mo, d})]
        end,
      {"parts->time", "(parts->time Y MO D H MI) — convert local date parts to unix seconds."} =>
        fn [y, mo, d, h, mi] ->
          case :calendar.local_time_to_universal_time_dst({{y, mo, d}, {h, mi, 0}}) do
            [utc | _] -> :calendar.datetime_to_gregorian_seconds(utc) - @unix_epoch_gregorian
            [] -> raise Eval.Error, message: "parts->time: invalid local time"
          end
        end,
      {"format-time",
       "(format-time SECS FMT) — format SECS as local time with the strftime pattern FMT."} =>
        fn [secs, fmt] ->
          {{y, mo, d}, {h, mi, s}} = :calendar.system_time_to_local_time(trunc(secs), :second)
          {:ok, ndt} = NaiveDateTime.new(y, mo, d, h, mi, s)
          Calendar.strftime(ndt, fmt)
        end,
      {"time+", "(time+ SECS DAYS) — return SECS moved forward by DAYS days."} => fn [secs, days] ->
        secs + days * 86_400
      end
    }
  end

  # compiled-regex cache: org refontification runs the same handful of
  # patterns on every change, so compile each pattern exactly once
  defp bytes_range(s, from, to) do
    if from < 0 or to < from or to > byte_size(s) do
      raise Eval.Error, message: "string-bytes: range #{from}..#{to} out of 0..#{byte_size(s)}"
    end

    s |> :binary.part(from, to - from) |> :binary.bin_to_list()
  end

  defp decode_int(s, from, width, endian) do
    if from < 0 or width < 1 or from + width > byte_size(s) do
      raise Eval.Error,
        message: "bytes->integer: #{from}+#{width} out of 0..#{byte_size(s)}"
    end

    :binary.decode_unsigned(:binary.part(s, from, width), endian_of(endian))
  end

  defp encode_int(n, width, endian) do
    if width < 1 or n < 0 or n >= 1 <<< (8 * width) do
      raise Eval.Error, message: "integer->bytes: #{n} does not fit in #{width} bytes"
    end

    case endian_of(endian) do
      :big -> <<n::big-size(width)-unit(8)>>
      :little -> <<n::little-size(width)-unit(8)>>
    end
  end

  defp endian_of("little"), do: :little
  defp endian_of(_), do: :big

  defp re!(pat) do
    key = {:compos_scheme_re, pat}

    case :persistent_term.get(key, nil) do
      nil ->
        case Regex.compile(pat, "u") do
          {:ok, re} ->
            :persistent_term.put(key, re)
            re

          {:error, {msg, at}} ->
            raise Eval.Error, message: "bad regex #{inspect(pat)}: #{msg} at #{at}"
        end

      re ->
        re
    end
  end

  defp arith(args, init, op) do
    Enum.reduce(args, init, fn x, acc when is_number(x) -> op.(acc, x) end)
  end

  defp sub([x]), do: -x
  defp sub([x | rest]), do: Enum.reduce(rest, x, fn b, a -> a - b end)

  defp divide([x | rest]), do: Enum.reduce(rest, x, fn b, a -> a / b end)

  defp floor_div([x]), do: floor(x)
  defp floor_div([a, b]) when is_integer(a) and is_integer(b), do: Integer.floor_div(a, b)
  defp floor_div([a, b]), do: floor(a / b)

  defp expt([b, p]) when is_integer(b) and is_integer(p) and p >= 0, do: Integer.pow(b, p)
  defp expt([b, p]), do: :math.pow(b, p)

  defp log([x]), do: :math.log(x)
  defp log([x, 10]), do: :math.log10(x)
  defp log([x, 2]), do: :math.log2(x)
  defp log([x, base]), do: :math.log(x) / :math.log(base)

  defp atan([y]), do: :math.atan(y)
  defp atan([y, x]), do: :math.atan2(y, x)

  # Walk the arguments in place. chunk_every built the whole list of
  # overlapping pairs first, so a comparison over a long list allocated a
  # second copy of it before Enum.all? could reject the first pair. On
  # 2026-09-09 one such call reached 368 MB of heap and passed the 1024 MB
  # limit, which killed the reactor rule that made it. This allocates
  # nothing and stops at the first pair that fails.
  defp cmp(op) do
    fn args -> cmp_pairs(args, op) end
  end

  defp cmp_pairs([a, b | rest], op) do
    if op.(a, b), do: cmp_pairs([b | rest], op), else: false
  end

  defp cmp_pairs(_args, _op), do: true

  # ~a inserts a value as text, ~s as its printed form (a string keeps its
  # quotes), ~% a newline, ~~ a tilde. Anything else is an error rather than
  # a silently copied directive: a wrong format string should say so.
  defp format_string(fmt, args) do
    {out, rest} = format_scan(String.graphemes(fmt), args, [])

    unless rest == [] do
      raise Eval.Error, message: "format: #{length(rest)} unused argument(s)"
    end

    IO.iodata_to_binary(out)
  end

  defp format_scan([], args, acc), do: {Enum.reverse(acc), args}

  defp format_scan(["~", d | _], [], _acc) when d in ["a", "s"] do
    raise Eval.Error, message: "format: no argument for ~#{d}"
  end

  defp format_scan(["~", "a" | t], [a | args], acc),
    do: format_scan(t, args, [format_display(a) | acc])

  defp format_scan(["~", "s" | t], [a | args], acc),
    do: format_scan(t, args, [Printer.print(a) | acc])

  defp format_scan(["~", "%" | t], args, acc), do: format_scan(t, args, ["\n" | acc])
  defp format_scan(["~", "~" | t], args, acc), do: format_scan(t, args, ["~" | acc])

  defp format_scan(["~", d | _], _args, _acc) do
    raise Eval.Error, message: "format: unknown directive ~#{d}"
  end

  defp format_scan([c | t], args, acc), do: format_scan(t, args, [c | acc])

  # ~a shows a string bare; every other value prints
  defp format_display(v) when is_binary(v), do: v
  defp format_display(v), do: Printer.print(v)

  # keep the elements whose PRED answer is truthy (KEEP true) or false
  defp select(pred, l, store, keep) do
    {kept, store} =
      Enum.reduce(l, {[], store}, fn x, {acc, store} ->
        {answer, store} = Eval.apply_fn(pred, [x], store)
        {if(answer != false == keep, do: [x | acc], else: acc), store}
      end)

    {Enum.reverse(kept), store}
  end

  defp plist_get([k, v | _], key) when k == key, do: v
  defp plist_get([_, _ | rest], key), do: plist_get(rest, key)
  defp plist_get(_, _key), do: false
  defp plist_delete([k, _ | rest], key) when k == key, do: plist_delete(rest, key)
  defp plist_delete([k, v | rest], key), do: [k, v | plist_delete(rest, key)]
  defp plist_delete(_, _key), do: []
  defp source_callable({:interposed, original, _}), do: source_callable(original)
  defp source_callable(value), do: value
end
