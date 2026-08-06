defmodule Aimax.Scheme.Builtins do
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
      "cons" => fn [h, t] when is_list(t) -> [h | t] end,
      "car" => fn [[h | _]] -> h end,
      "cdr" => fn [[_ | t]] -> t end,
      "list" => fn args -> args end,
      "null?" => fn [x] -> x == [] end,
      "pair?" => fn [x] -> is_list(x) and x != [] end,
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
      "string-index" => fn [s, sub] ->
        case :binary.match(s, sub) do
          :nomatch -> false
          {pos, _len} -> pos
        end
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

        :binary.part(s, from, to - from)
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
end
