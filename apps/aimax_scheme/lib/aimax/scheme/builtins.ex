defmodule Aimax.Scheme.Builtins do
  alias Aimax.Scheme.Text

  @moduledoc """
  Core builtins. Higher-order library functions (map/filter/etc.) live in the
  Scheme prelude instead — they need `apply`, which the prelude gets for free.
  """

  alias Aimax.Scheme.{Eval, Printer}

  # :calendar.datetime_to_gregorian_seconds at the unix epoch
  @unix_epoch_gregorian 62_167_219_200

  def all do
    %{
      "+" => &arith(&1, 0, fn a, b -> a + b end),
      "*" => &arith(&1, 1, fn a, b -> a * b end),
      "-" => &sub/1,
      "/" => &divide/1,
      "=" => cmp(fn a, b -> a == b end),
      "<" => cmp(fn a, b -> a < b end),
      ">" => cmp(fn a, b -> a > b end),
      "<=" => cmp(fn a, b -> a <= b end),
      ">=" => cmp(fn a, b -> a >= b end),
      "equal?" => fn [a, b] -> a == b end,
      "not" => fn [a] -> a == false end,
      "modulo" => fn [a, b] -> Integer.mod(a, b) end,
      "remainder" => fn [a, b] -> rem(a, b) end,
      "quotient" => fn [a, b] -> div(a, b) end,
      "min" => fn args -> Enum.min(args) end,
      "max" => fn args -> Enum.max(args) end,
      "abs" => fn [x] -> abs(x) end,
      "member" => fn [x, l] ->
        case Enum.drop_while(l, &(&1 != x)) do
          [] -> false
          tail -> tail
        end
      end,
      "sort" => fn [l] -> Enum.sort(l) end,
      # any tail, not only a list: the reader reads (a . b), so cons must
      # build it too. list? tells a proper list from a dotted pair.
      "cons" => fn [h, t] -> [h | t] end,
      "car" => fn [[h | _]] -> h end,
      "cdr" => fn [[_ | t]] -> t end,
      "list" => fn args -> args end,
      "null?" => fn [x] -> x == [] end,
      "pair?" => fn [x] -> is_list(x) and x != [] end,
      "list?" => fn [x] -> proper_list?(x) end,
      "char?" => fn [x] -> match?({:char, _}, x) end,
      "char->integer" => fn [{:char, cp}] -> cp end,
      "integer->char" => fn [i] when is_integer(i) -> {:char, i} end,
      "string->char" => fn [<<cp::utf8, _::binary>>] -> {:char, cp} end,
      "char->string" => fn [{:char, cp}] -> <<cp::utf8>> end,
      "length" => fn [l] -> length(l) end,
      "append" => fn lists -> Enum.concat(lists) end,
      "reverse" => fn [l] -> Enum.reverse(l) end,
      "number?" => fn [x] -> is_number(x) end,
      "string?" => fn [x] -> is_binary(x) end,
      "symbol?" => fn [x] -> match?({:sym, _}, x) end,
      "procedure?" => fn [x] -> match?({:closure, _, _, _}, x) or match?({:builtin, _, _}, x) end,
      # introspection: closures carry their AST, so userland functions can
      # print their own source; builtins are opaque Elixir
      "function-source" => fn [v] ->
        case v do
          {:closure, {req, opt, rest}, body, _env} ->
            params =
              req ++
                if(opt == [], do: [], else: ["&optional" | opt]) ++
                if(rest, do: ["&rest", rest], else: [])

            Aimax.Scheme.Printer.print([
              {:sym, "lambda"},
              Enum.map(params, &{:sym, &1}) | body
            ])

          {:builtin, name, _} ->
            "#<builtin #{name} — implemented in Elixir, no Scheme source>"

          other ->
            Aimax.Scheme.Printer.print(other)
        end
      end,
      "string-append" => fn args -> Enum.join(args) end,
      "string-length" => fn [s] -> String.length(s) end,
      "string-contains?" => fn [s, sub] -> String.contains?(s, sub) end,
      "string-prefix?" => fn [pre, s] -> String.starts_with?(s, pre) end,
      "string-suffix?" => fn [suf, s] -> String.ends_with?(s, suf) end,
      "string-rindex" => fn [s, sub] ->
        case :binary.matches(s, sub) do
          [] -> false
          matches -> matches |> List.last() |> elem(0)
        end
      end,
      "common-prefix" => fn [strings] ->
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
      "string-index" => fn
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
      "string-upcase" => fn [s] -> String.upcase(s) end,
      "string-downcase" => fn [s] -> String.downcase(s) end,
      "string-trim" => fn [s] -> String.trim(s) end,
      "string-repeat" => fn [s, n] -> String.duplicate(s, n) end,
      # byte-offset variants: compose with point/overlay/search positions,
      # which are all byte-based (grapheme substring/string-length are not)
      "string-byte-length" => fn [s] -> byte_size(s) end,
      "substring-bytes" => fn [s, from, to] ->
        if from < 0 or to < from or to > byte_size(s) do
          raise Eval.Error, message: "substring-bytes: range #{from}..#{to} out of 0..#{byte_size(s)}"
        end

        # snap both ends down to codepoint boundaries (Text says why)
        Text.slice(s, from, to)
      end,
      # binary-safe transport encoding (MCP proxy, anything crossing RPC
      # where printed-string escaping would be ambiguous)
      "base64-encode" => fn [s] -> Base.encode64(s) end,
      "base64-decode" => fn [s] ->
        case Base.decode64(s) do
          {:ok, v} -> v
          :error -> raise Eval.Error, message: "base64-decode: invalid input"
        end
      end,
      "string-split" => fn [s, sep] -> String.split(s, sep) end,
      "string-join" => fn [parts, sep] -> Enum.join(parts, sep) end,
      "string-pad-left" => fn [s, n] -> String.pad_leading(s, n) end,
      "string-pad-right" => fn [s, n] -> String.pad_trailing(s, n) end,
      "substring" => fn [s, from, to] -> String.slice(s, from, to - from) end,
      "number->string" => fn [n] -> Printer.print(n) end,
      "value->string" => fn [v] -> Printer.print(v) end,
      "string->number" => fn [s] ->
        case Integer.parse(s) do
          {i, ""} -> i
          _ -> with {f, ""} <- Float.parse(s), do: f
        end
      end,
      "symbol->string" => fn [{:sym, s}] -> s end,
      "string->symbol" => fn [s] -> {:sym, s} end,
      "apply" => fn [f, args], store -> Eval.apply_fn(f, args, store) end,
      "display" => fn [x] ->
        IO.write(Printer.display(x))
        :void
      end,
      "newline" => fn [] ->
        IO.write("\n")
        :void
      end,
      "error" => fn args ->
        raise Eval.Error, message: Enum.map_join(args, " ", &Printer.display/1)
      end,
      "re-match?" => fn [pat, s] -> Regex.match?(re!(pat), s) end,
      "re-match" => fn [pat, s] ->
        case Regex.run(re!(pat), s) do
          nil -> false
          groups -> groups
        end
      end,
      "re-find" => fn [pat, s, start] ->
        case Regex.run(re!(pat), s, return: :index, offset: start) do
          nil -> false
          [{ms, len} | _] -> [ms, ms + len]
        end
      end,
      "re-find*" => fn [pat, s] ->
        re!(pat)
        |> Regex.scan(s, return: :index)
        |> Enum.map(fn [{ms, len} | _] -> [ms, ms + len] end)
      end,
      "re-groups" => fn [pat, s, start] ->
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
      "re-replace" => fn [pat, s, repl] -> Regex.replace(re!(pat), s, repl, global: false) end,
      "re-replace-all" => fn [pat, s, repl] -> Regex.replace(re!(pat), s, repl) end,
      "current-time" => fn [] -> System.os_time(:second) end,
      "time->parts" => fn [secs] ->
        {{y, mo, d}, {h, mi, _s}} = :calendar.system_time_to_local_time(trunc(secs), :second)
        [y, mo, d, h, mi, :calendar.day_of_the_week({y, mo, d})]
      end,
      "parts->time" => fn [y, mo, d, h, mi] ->
        case :calendar.local_time_to_universal_time_dst({{y, mo, d}, {h, mi, 0}}) do
          [utc | _] -> :calendar.datetime_to_gregorian_seconds(utc) - @unix_epoch_gregorian
          [] -> raise Eval.Error, message: "parts->time: invalid local time"
        end
      end,
      "format-time" => fn [secs, fmt] ->
        {{y, mo, d}, {h, mi, s}} = :calendar.system_time_to_local_time(trunc(secs), :second)
        {:ok, ndt} = NaiveDateTime.new(y, mo, d, h, mi, s)
        Calendar.strftime(ndt, fmt)
      end,
      "time+" => fn [secs, days] -> secs + days * 86_400 end
    }
  end

  def docs do
    %{
      "+" => "(+ N ...) — return the sum of the numbers; 0 with no arguments.",
      "*" => "(* N ...) — return the product of the numbers; 1 with no arguments.",
      "-" => "(- N ...) — negate N, or subtract the other numbers from N in order.",
      "/" => "(/ N ...) — divide N by the other numbers in order; return a float.",
      "=" => "(= N ...) — return true if each number equals the next.",
      "<" => "(< N ...) — return true if each number is less than the next.",
      ">" => "(> N ...) — return true if each number is greater than the next.",
      "<=" => "(<= N ...) — return true if each number is less than or equal to the next.",
      ">=" => "(>= N ...) — return true if each number is greater than or equal to the next.",
      "equal?" => "(equal? A B) — return true if A and B are structurally equal.",
      "not" => "(not X) — return true if X is false.",
      "modulo" => "(modulo A B) — return A modulo B; the result takes the sign of B.",
      "remainder" => "(remainder A B) — return the remainder of A/B; the result takes the sign of A.",
      "quotient" => "(quotient A B) — return the integer quotient of A/B, truncated toward zero.",
      "min" => "(min N ...) — return the smallest of the numbers.",
      "max" => "(max N ...) — return the largest of the numbers.",
      "abs" => "(abs N) — return the absolute value of N.",
      "member" => "(member X LST) — return the tail of LST from the first X, or false.",
      "sort" => "(sort LST) — return LST sorted in ascending term order.",
      "cons" => "(cons H T) — prepend H to T. A non-list T makes a dotted pair.",
      "list?" => "(list? X) — return true if X is a proper list.",
      "char?" => "(char? X) — return true if X is a character.",
      "char->integer" => "(char->integer C) — return the codepoint of C.",
      "integer->char" => "(integer->char N) — return the character for codepoint N.",
      "string->char" => "(string->char S) — return the first character of S.",
      "char->string" => "(char->string C) — return C as a one-character string.",
      "car" => "(car LST) — return the first element of LST.",
      "cdr" => "(cdr LST) — return LST without its first element.",
      "list" => "(list X ...) — return a list of the arguments.",
      "null?" => "(null? X) — return true if X is the empty list.",
      "pair?" => "(pair? X) — return true if X is a non-empty list.",
      "length" => "(length LST) — return the number of elements in LST.",
      "append" => "(append LST ...) — concatenate the lists into one list.",
      "reverse" => "(reverse LST) — return LST with its elements in reverse order.",
      "number?" => "(number? X) — return true if X is a number.",
      "string?" => "(string? X) — return true if X is a string.",
      "symbol?" => "(symbol? X) — return true if X is a symbol.",
      "procedure?" => "(procedure? X) — return true if X is a closure or a builtin.",
      "function-source" => "(function-source F) — return the lambda source of F; builtins report as opaque.",
      "string-append" => "(string-append S ...) — concatenate the strings into one string.",
      "string-length" => "(string-length S) — return the count of characters in S, not bytes.",
      "string-contains?" => "(string-contains? S SUB) — return true if S contains SUB.",
      "string-prefix?" => "(string-prefix? PRE S) — return true if S starts with PRE.",
      "string-suffix?" => "(string-suffix? SUF S) — return true if S ends with SUF.",
      "string-rindex" => "(string-rindex S SUB) — return the byte offset of the last SUB in S, or false.",
      "common-prefix" => "(common-prefix STRINGS) — return the longest common prefix of the list of strings.",
      "string-index" =>
        "(string-index S SUB [START]) — return the byte offset of the first SUB in S at or after START, or false.",
      "string-upcase" => "(string-upcase S) — return S converted to upper case.",
      "string-downcase" => "(string-downcase S) — return S converted to lower case.",
      "string-trim" => "(string-trim S) — return S without leading and trailing whitespace.",
      "string-repeat" => "(string-repeat S N) — return S repeated N times.",
      "string-byte-length" => "(string-byte-length S) — return the length of S in bytes.",
      "substring-bytes" => "(substring-bytes S FROM TO) — return the byte range FROM..TO, snapped to codepoint boundaries.",
      "base64-encode" => "(base64-encode S) — return S encoded as base64.",
      "base64-decode" => "(base64-decode S) — decode the base64 string S; error on invalid input.",
      "string-split" => "(string-split S SEP) — split S on the separator SEP into a list.",
      "string-join" => "(string-join PARTS SEP) — join the list PARTS into one string with SEP between.",
      "string-pad-left" => "(string-pad-left S N) — pad S with leading spaces to N characters.",
      "string-pad-right" => "(string-pad-right S N) — pad S with trailing spaces to N characters.",
      "substring" => "(substring S FROM TO) — return the character range FROM..TO of S, not bytes.",
      "number->string" => "(number->string N) — return N printed as a string.",
      "value->string" => "(value->string V) — return V printed as a string.",
      "string->number" => "(string->number S) — parse S as an integer or a float.",
      "symbol->string" => "(symbol->string SYM) — return the name of SYM as a string.",
      "string->symbol" => "(string->symbol S) — return the symbol with the name S.",
      "apply" => "(apply F ARGS) — call F with the elements of the list ARGS as arguments.",
      "display" => "(display X) — write X to standard output without quotes.",
      "newline" => "(newline) — write a newline to standard output.",
      "error" => "(error X ...) — raise an error; the message joins the displayed arguments with spaces.",
      "re-match?" => "(re-match? PAT S) — return true if the regex PAT matches S.",
      "re-match" => "(re-match PAT S) — return the matched strings (match, then groups), or false.",
      "re-groups" => "(re-groups PAT S START) — return [START END] byte pairs per group; false for unmatched groups.",
      "re-find" => "(re-find PAT S START) — return [START END] byte offsets of the first match, or false.",
      "re-find*" => "(re-find* PAT S) — return [START END] byte offsets for every match of PAT in S.",
      "re-replace" => "(re-replace PAT S REPL) — replace the first match of PAT in S with REPL.",
      "re-replace-all" => "(re-replace-all PAT S REPL) — replace every match of PAT in S with REPL.",
      "current-time" => "(current-time) — return the current time as unix seconds.",
      "time->parts" => "(time->parts SECS) — return local [YEAR MONTH DAY HOUR MINUTE WEEKDAY]; Monday is 1.",
      "parts->time" => "(parts->time Y MO D H MI) — convert local date parts to unix seconds.",
      "format-time" => "(format-time SECS FMT) — format SECS as local time with the strftime pattern FMT.",
      "time+" => "(time+ SECS DAYS) — return SECS moved forward by DAYS days."
    }
  end

  # compiled-regex cache: org refontification runs the same handful of
  # patterns on every change, so compile each pattern exactly once
  defp re!(pat) do
    key = {:aimax_scheme_re, pat}

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

  defp cmp(op) do
    fn args ->
      args |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> op.(a, b) end)
    end
  end


  defp proper_list?([]), do: true
  defp proper_list?([_ | t]), do: proper_list?(t)
  defp proper_list?(_), do: false
end
