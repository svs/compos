defmodule Aimax.Scheme.Reader do
  @moduledoc """
  S-expression reader: text -> Elixir terms.

  Value mapping:
    * symbols  -> `{:sym, "name"}`   (never atoms — user code must not grow the atom table)
    * numbers  -> integer | float
    * strings  -> binary
    * chars    -> `{:char, codepoint}`
    * booleans -> `true` | `false`  (#t / #f)
    * lists    -> Elixir lists; `(a . b)` reads as the improper list `[a | b]`

  Syntax the reader accepts:

      'x  `x  ,x  ,@x       quote, quasiquote, unquote, unquote-splicing
      (a . b)               dotted pair
      #\\a #\\space #\\x41    characters
      #t #f #true #false    booleans
      #x1f #o17 #b1010 #d9  radix prefixes
      |a symbol|            symbol with any characters in the name
      ; line                line comment
      #| nested |#          block comment, nests
      #;datum               datum comment: the reader drops the next form

  Every error names a line and a column.
  """

  defmodule Error do
    @moduledoc """
    A syntax error, with the line and the column of the offending text.
    `incomplete: true` means the text stops inside a form. More text can
    still make it valid, so a REPL asks for the next line instead of
    reporting the error.
    """
    defexception [:message, :line, :column, incomplete: false]
  end

  @doc "Read all top-level forms from a string."
  def read_all(src) do
    src |> tokenize() |> read_forms([])
  end

  @doc """
  Read one form. Returns `{:ok, form, rest_of_source}`, `{:incomplete, reason}`
  when the text stops inside a list or a string, or `{:error, exception}`.

  The REPL and the RPC reader use this: `:incomplete` means "ask for more
  text", an error means "report it now".
  """
  def read_one(src) do
    case tokenize(src) do
      [] ->
        {:incomplete, "empty input"}

      tokens ->
        {form, rest} = read_expr(tokens)
        {:ok, form, rest_source(rest, src)}
    end
  rescue
    e in Error -> if e.incomplete, do: {:incomplete, e.message}, else: {:error, e}
  end

  # the tokens carry offsets, so the unread tail is a slice of the source
  defp rest_source([], _src), do: ""

  defp rest_source([{_tag, _val, _line, _col, offset} | _], src),
    do: binary_part(src, offset, byte_size(src) - offset)

  defp read_forms([], acc), do: Enum.reverse(acc)

  defp read_forms(tokens, acc) do
    {form, rest} = read_expr(tokens)
    read_forms(rest, [form | acc])
  end

  defp fail(msg, line, col, incomplete \\ false) do
    raise Error,
      message: "line #{line}, column #{col}: #{msg}",
      line: line,
      column: col,
      incomplete: incomplete
  end

  # --- tokenizer -------------------------------------------------------------
  #
  # A token is {tag, value, line, column, byte_offset}. The position rides on
  # every token so the parser can name a line and a column for any error.

  @delims ~c[ \t\r\n()";'`,|]

  defp tokenize(src), do: tok(src, 1, 1, byte_size(src), [])

  defp tok(<<>>, _l, _c, _n, acc), do: Enum.reverse(acc)

  defp tok(<<"\n", rest::binary>>, l, _c, n, acc), do: tok(rest, l + 1, 1, n, acc)

  defp tok(<<ch, rest::binary>>, l, c, n, acc) when ch in ~c[ \t\r],
    do: tok(rest, l, c + 1, n, acc)

  defp tok(<<";", rest::binary>>, l, c, n, acc) do
    {rest, l, c} = skip_line(rest, l, c + 1)
    tok(rest, l, c, n, acc)
  end

  defp tok(<<"#|", rest::binary>>, l, c, n, acc) do
    {rest, l, c} = skip_block(rest, l, c + 2, 1)
    tok(rest, l, c, n, acc)
  end

  defp tok(<<"#;", rest::binary>> = bin, l, c, n, acc),
    do: tok(rest, l, c + 2, n, [{:datum_comment, nil, l, c, off(n, bin)} | acc])

  defp tok(<<"#\\", rest::binary>> = bin, l, c, n, acc) do
    {cp, rest, width} = tok_char(rest, l, c)
    tok(rest, l, c + 2 + width, n, [{:char, cp, l, c, off(n, bin)} | acc])
  end

  defp tok(<<"(", rest::binary>> = bin, l, c, n, acc),
    do: tok(rest, l, c + 1, n, [{:lparen, nil, l, c, off(n, bin)} | acc])

  defp tok(<<")", rest::binary>> = bin, l, c, n, acc),
    do: tok(rest, l, c + 1, n, [{:rparen, nil, l, c, off(n, bin)} | acc])

  defp tok(<<"'", rest::binary>> = bin, l, c, n, acc),
    do: tok(rest, l, c + 1, n, [{:quote, nil, l, c, off(n, bin)} | acc])

  defp tok(<<"`", rest::binary>> = bin, l, c, n, acc),
    do: tok(rest, l, c + 1, n, [{:quasiquote, nil, l, c, off(n, bin)} | acc])

  defp tok(<<",@", rest::binary>> = bin, l, c, n, acc),
    do: tok(rest, l, c + 2, n, [{:unquote_splicing, nil, l, c, off(n, bin)} | acc])

  defp tok(<<",", rest::binary>> = bin, l, c, n, acc),
    do: tok(rest, l, c + 1, n, [{:unquote, nil, l, c, off(n, bin)} | acc])

  defp tok(<<"\"", rest::binary>> = bin, l, c, n, acc) do
    {str, rest, l2, c2} = tok_string(rest, l, c + 1, [], {l, c})
    tok(rest, l2, c2, n, [{:str, str, l, c, off(n, bin)} | acc])
  end

  # |a symbol with spaces|
  defp tok(<<"|", rest::binary>> = bin, l, c, n, acc) do
    {name, rest, l2, c2} = tok_bar(rest, l, c + 1, [])
    tok(rest, l2, c2, n, [{:atom, {:sym, name}, l, c, off(n, bin)} | acc])
  end

  defp tok(bin, l, c, n, acc) do
    {text, rest, width} = tok_atom(bin, [], 0)

    token =
      if text == ".",
        do: {:dot, nil, l, c, off(n, bin)},
        else: {:atom, parse_atom(text, l, c), l, c, off(n, bin)}

    tok(rest, l, c + width, n, [token | acc])
  end

  # the byte offset where a token starts: the whole source minus what was
  # still unread when the tokenizer reached it
  defp off(n, bin), do: n - byte_size(bin)

  defp skip_line(<<>>, l, c), do: {<<>>, l, c}
  defp skip_line(<<"\n", rest::binary>>, l, _c), do: {rest, l + 1, 1}
  defp skip_line(<<_, rest::binary>>, l, c), do: skip_line(rest, l, c + 1)

  defp skip_block(<<>>, l, c, _depth), do: fail("unterminated block comment", l, c, true)
  defp skip_block(<<"|#", rest::binary>>, l, c, 1), do: {rest, l, c + 2}
  defp skip_block(<<"|#", rest::binary>>, l, c, d), do: skip_block(rest, l, c + 2, d - 1)
  defp skip_block(<<"#|", rest::binary>>, l, c, d), do: skip_block(rest, l, c + 2, d + 1)
  defp skip_block(<<"\n", rest::binary>>, l, _c, d), do: skip_block(rest, l + 1, 1, d)
  defp skip_block(<<_::utf8, rest::binary>>, l, c, d), do: skip_block(rest, l, c + 1, d)

  # --- strings ---------------------------------------------------------------

  # the error points at the opening quote, not at the end of the file
  defp tok_string(<<>>, _l, _c, _acc, {sl, sc}), do: fail("unterminated string", sl, sc, true)

  defp tok_string(<<"\"", rest::binary>>, l, c, acc, _start),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest, l, c + 1}

  # \x41; is a hex codepoint. Anything else after \x is not an escape at all,
  # so the reader keeps both characters: regex strings hold "\\x" sequences.
  defp tok_string(<<"\\x", rest::binary>>, l, c, acc, start) do
    case scan_hex(rest, []) do
      {cp, rest, width} -> tok_string(rest, l, c + 2 + width, [<<cp::utf8>> | acc], start)
      nil -> tok_string(rest, l, c + 2, ["\\x" | acc], start)
    end
  end

  # \<newline> with intraline space around it folds away: a long string can
  # wrap in the source and stay one line of text
  defp tok_string(<<"\\", rest::binary>>, l, c, acc, start) do
    case skip_intraline(rest) do
      <<"\n", rest2::binary>> ->
        tok_string(skip_intraline(rest2), l + 1, 1, acc, start)

      <<>> ->
        {sl, sc} = start
        fail("unterminated string", sl, sc, true)

      _ ->
        <<esc, rest2::binary>> = rest
        tok_string(rest2, l, c + 2, [string_escape(esc) | acc], start)
    end
  end

  defp tok_string(<<"\n", rest::binary>>, l, _c, acc, start),
    do: tok_string(rest, l + 1, 1, ["\n" | acc], start)

  defp tok_string(<<ch::utf8, rest::binary>>, l, c, acc, start),
    do: tok_string(rest, l, c + 1, [<<ch::utf8>> | acc], start)

  defp skip_intraline(<<ch, rest::binary>>) when ch in ~c[ \t], do: skip_intraline(rest)
  defp skip_intraline(bin), do: bin

  defp string_escape(?n), do: "\n"
  defp string_escape(?t), do: "\t"
  defp string_escape(?r), do: "\r"
  defp string_escape(?a), do: <<7>>
  defp string_escape(?b), do: <<8>>
  defp string_escape(?0), do: <<0>>
  defp string_escape(?\\), do: "\\"
  defp string_escape(?"), do: "\""
  # not an escape: keep the backslash and the character, so a string can hold
  # a regex ("^\\*+ ") without doubling every backslash
  defp string_escape(ch), do: <<?\\, ch>>

  # hex digits then a semicolon, or nil
  defp scan_hex(<<";", _::binary>>, []), do: nil
  defp scan_hex(<<";", rest::binary>>, acc), do: {digits_to_int(acc, 16), rest, length(acc) + 1}

  defp scan_hex(<<ch, rest::binary>>, acc) when ch in ~c[0123456789abcdefABCDEF],
    do: scan_hex(rest, [ch | acc])

  defp scan_hex(_bin, _acc), do: nil

  defp digits_to_int(rev_digits, base),
    do: rev_digits |> Enum.reverse() |> IO.iodata_to_binary() |> String.to_integer(base)

  # --- bar symbols -----------------------------------------------------------

  defp tok_bar(<<>>, l, c, _acc), do: fail("unterminated |symbol|", l, c, true)

  defp tok_bar(<<"|", rest::binary>>, l, c, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest, l, c + 1}

  defp tok_bar(<<"\\|", rest::binary>>, l, c, acc), do: tok_bar(rest, l, c + 2, ["|" | acc])
  defp tok_bar(<<"\\\\", rest::binary>>, l, c, acc), do: tok_bar(rest, l, c + 2, ["\\" | acc])
  defp tok_bar(<<"\n", rest::binary>>, l, _c, acc), do: tok_bar(rest, l + 1, 1, ["\n" | acc])

  defp tok_bar(<<ch::utf8, rest::binary>>, l, c, acc),
    do: tok_bar(rest, l, c + 1, [<<ch::utf8>> | acc])

  # --- characters ------------------------------------------------------------

  @char_names %{
    "space" => ?\s,
    "newline" => ?\n,
    "linefeed" => ?\n,
    "tab" => ?\t,
    "return" => ?\r,
    "nul" => 0,
    "null" => 0,
    "alarm" => 7,
    "backspace" => 8,
    "escape" => 27,
    "esc" => 27,
    "delete" => 127,
    "rubout" => 127
  }

  defp tok_char(<<>>, l, c), do: fail("unterminated character literal", l, c, true)

  defp tok_char(bin, l, c) do
    {name, rest, width} = tok_atom(bin, [], 0)

    case name do
      # an empty name means tok_atom stopped at once, on a delimiter. A
      # delimiter is a character too: #\( #\) #\" #\; and #\<space>.
      "" ->
        <<ch::utf8, rest2::binary>> = bin
        {ch, rest2, 1}

      <<ch::utf8>> ->
        {ch, rest, width}

      <<"x", hex::binary>> when byte_size(hex) > 0 ->
        case Integer.parse(hex, 16) do
          {cp, ""} -> {cp, rest, width}
          _ -> named_char(name, rest, width, l, c)
        end

      _ ->
        named_char(name, rest, width, l, c)
    end
  end

  defp named_char(name, rest, width, l, c) do
    case Map.fetch(@char_names, String.downcase(name)) do
      {:ok, cp} -> {cp, rest, width}
      :error -> fail("unknown character name #\\#{name}", l, c)
    end
  end

  # --- atoms -----------------------------------------------------------------

  defp tok_atom(<<>>, acc, width),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>, width}

  defp tok_atom(<<ch, _::binary>> = bin, acc, width) when ch in @delims,
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), bin, width}

  defp tok_atom(<<ch::utf8, rest::binary>>, acc, width),
    do: tok_atom(rest, [<<ch::utf8>> | acc], width + 1)

  defp parse_atom("#t", _l, _c), do: true
  defp parse_atom("#true", _l, _c), do: true
  defp parse_atom("#f", _l, _c), do: false
  defp parse_atom("#false", _l, _c), do: false

  defp parse_atom(<<"#", prefix, digits::binary>>, l, c) when prefix in ~c[xXoObBdD] do
    base = radix(prefix)
    {sign, digits} = sign_of(digits)

    case Integer.parse(digits, base) do
      {i, ""} when digits != "" -> sign * i
      _ -> fail("bad number #{<<?#, prefix>>}#{digits}", l, c)
    end
  end

  defp parse_atom(<<"#", _::binary>> = a, l, c), do: fail("unknown # syntax #{a}", l, c)

  defp parse_atom(a, _l, _c) do
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

  defp radix(p) when p in ~c[xX], do: 16
  defp radix(p) when p in ~c[oO], do: 8
  defp radix(p) when p in ~c[bB], do: 2
  defp radix(p) when p in ~c[dD], do: 10

  defp sign_of(<<"-", rest::binary>>), do: {-1, rest}
  defp sign_of(<<"+", rest::binary>>), do: {1, rest}
  defp sign_of(digits), do: {1, digits}

  # --- parser ----------------------------------------------------------------

  defp read_expr([]),
    do: raise(Error, message: "unexpected end of input", line: 0, column: 0, incomplete: true)

  defp read_expr([{:lparen, _, l, c, _} | rest]), do: read_list(rest, [], l, c)
  defp read_expr([{:rparen, _, l, c, _} | _]), do: fail("unexpected )", l, c)
  defp read_expr([{:dot, _, l, c, _} | _]), do: fail("unexpected . outside a list", l, c)

  defp read_expr([{:datum_comment, _, _l, _c, _} | rest]) do
    {_dropped, rest} = read_expr(rest)
    read_expr(rest)
  end

  defp read_expr([{prefix, _, _l, _c, _} | rest])
       when prefix in [:quote, :quasiquote, :unquote, :unquote_splicing] do
    {form, rest} = read_expr(rest)
    {[{:sym, prefix_name(prefix)}, form], rest}
  end

  defp read_expr([{:str, s, _l, _c, _} | rest]), do: {s, rest}
  defp read_expr([{:char, cp, _l, _c, _} | rest]), do: {{:char, cp}, rest}
  defp read_expr([{:atom, a, _l, _c, _} | rest]), do: {a, rest}

  defp prefix_name(:quote), do: "quote"
  defp prefix_name(:quasiquote), do: "quasiquote"
  defp prefix_name(:unquote), do: "unquote"
  defp prefix_name(:unquote_splicing), do: "unquote-splicing"

  defp read_list([{:rparen, _, _, _, _} | rest], acc, _l, _c), do: {Enum.reverse(acc), rest}
  defp read_list([], _acc, l, c), do: fail("unterminated list", l, c, true)

  # (a . b) — the tail after the dot becomes the improper tail of the list
  defp read_list([{:dot, _, dl, dc, _} | rest], acc, l, c) do
    if acc == [], do: fail("a dotted pair needs a value before the .", dl, dc)

    {tail, rest} = read_expr(rest)

    case rest do
      [{:rparen, _, _, _, _} | rest] -> {improper(Enum.reverse(acc), tail), rest}
      [] -> fail("unterminated list", l, c, true)
      [{_, _, tl, tc, _} | _] -> fail("a dotted pair takes one value after the .", tl, tc)
    end
  end

  defp read_list([{:datum_comment, _, _, _, _} | rest], acc, l, c) do
    {_dropped, rest} = read_expr(rest)
    read_list(rest, acc, l, c)
  end

  defp read_list(tokens, acc, l, c) do
    {form, rest} = read_expr(tokens)
    read_list(rest, [form | acc], l, c)
  end

  # (a . (b c)) is (a b c): a list tail flattens, anything else stays improper
  defp improper(head, tail) when is_list(tail), do: head ++ tail
  defp improper(head, tail), do: List.foldr(head, tail, fn x, t -> [x | t] end)
end
