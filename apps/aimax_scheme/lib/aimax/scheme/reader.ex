defmodule Aimax.Scheme.Reader do
  @moduledoc """
  S-expression reader: text -> Elixir terms.

  Value mapping:
    * symbols  -> `{:sym, "name"}`   (never atoms — user code must not grow the atom table)
    * numbers  -> integer | float
    * strings  -> binary
    * booleans -> `true` | `false`  (#t / #f)
    * lists    -> Elixir lists
  """

  defmodule Error do
    defexception [:message]
  end

  @doc "Read all top-level forms from a string."
  def read_all(src) do
    tokens = tokenize(src)
    read_forms(tokens, [])
  end

  @doc "Read a single form; returns {form, remaining_tokens}."
  def read_one(src) do
    src |> tokenize() |> read_expr()
  end

  defp read_forms([], acc), do: Enum.reverse(acc)

  defp read_forms(tokens, acc) do
    {form, rest} = read_expr(tokens)
    read_forms(rest, [form | acc])
  end

  # --- tokenizer -------------------------------------------------------------

  defp tokenize(src), do: tok(src, [])

  defp tok(<<>>, acc), do: Enum.reverse(acc)
  defp tok(<<c, rest::binary>>, acc) when c in ~c[ \t\r\n], do: tok(rest, acc)
  defp tok(<<";", rest::binary>>, acc), do: tok(skip_line(rest), acc)
  defp tok(<<"(", rest::binary>>, acc), do: tok(rest, [:lparen | acc])
  defp tok(<<")", rest::binary>>, acc), do: tok(rest, [:rparen | acc])
  defp tok(<<"'", rest::binary>>, acc), do: tok(rest, [:quote | acc])

  defp tok(<<"\"", rest::binary>>, acc) do
    {str, rest} = tok_string(rest, [])
    tok(rest, [{:str, str} | acc])
  end

  defp tok(bin, acc) do
    {atom, rest} = tok_atom(bin, [])
    tok(rest, [{:atom, atom} | acc])
  end

  defp skip_line(<<>>), do: <<>>
  defp skip_line(<<"\n", rest::binary>>), do: rest
  defp skip_line(<<_, rest::binary>>), do: skip_line(rest)

  defp tok_string(<<>>, _), do: raise(Error, message: "unterminated string")
  defp tok_string(<<"\"", rest::binary>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp tok_string(<<"\\\"", rest::binary>>, acc), do: tok_string(rest, ["\"" | acc])
  defp tok_string(<<"\\\\", rest::binary>>, acc), do: tok_string(rest, ["\\" | acc])
  defp tok_string(<<"\\n", rest::binary>>, acc), do: tok_string(rest, ["\n" | acc])
  defp tok_string(<<"\\t", rest::binary>>, acc), do: tok_string(rest, ["\t" | acc])
  defp tok_string(<<c::utf8, rest::binary>>, acc), do: tok_string(rest, [<<c::utf8>> | acc])

  defp tok_atom(<<c, _::binary>> = bin, acc) when c in ~c[ \t\r\n()";'] or bin == <<>> do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), bin}
  end

  defp tok_atom(<<c::utf8, rest::binary>>, acc), do: tok_atom(rest, [<<c::utf8>> | acc])
  defp tok_atom(<<>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  # --- parser ----------------------------------------------------------------

  defp read_expr([]), do: raise(Error, message: "unexpected end of input")
  defp read_expr([:lparen | rest]), do: read_list(rest, [])
  defp read_expr([:rparen | _]), do: raise(Error, message: "unexpected )")

  defp read_expr([:quote | rest]) do
    {form, rest} = read_expr(rest)
    {[{:sym, "quote"}, form], rest}
  end

  defp read_expr([{:str, s} | rest]), do: {s, rest}
  defp read_expr([{:atom, a} | rest]), do: {parse_atom(a), rest}

  defp read_list([:rparen | rest], acc), do: {Enum.reverse(acc), rest}
  defp read_list([], _), do: raise(Error, message: "unterminated list")

  defp read_list(tokens, acc) do
    {form, rest} = read_expr(tokens)
    read_list(rest, [form | acc])
  end

  defp parse_atom("#t"), do: true
  defp parse_atom("#f"), do: false

  defp parse_atom(a) do
    case Integer.parse(a) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(a) do
          {f, ""} -> f
          _ -> {:sym, a}
        end
    end
  end
end
