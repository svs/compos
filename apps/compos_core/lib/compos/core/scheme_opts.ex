defmodule Compos.Core.SchemeOpts do
  @moduledoc """
  The one conversion at the Scheme boundary.

  A primitive reads a Scheme option plist and works on one plain map. The
  conversion used to be written by hand in about fifty private helpers in
  `scheme_api.ex`. It lives here once: a symbol reads as its name, a bare
  key reads as `true`, and a list of symbols reads as a list of names.

  Policy is not here. Which options a builtin has, their defaults and their
  meaning stay in the Scheme wrapper that calls the builtin.
  """

  @doc "A Scheme option plist as a map with string keys. A bare key reads as `true`."
  def map(plist, value \\ &plain/1)
  def map(plist, value) when is_list(plist) do
    plist
    |> Enum.chunk_every(2)
    |> Map.new(fn
      [key, val] -> {plain(key), value.(val)}
      [key] -> {plain(key), true}
    end)
  end
  def map(_plist, _value), do: %{}

  @doc "A Scheme value as the plain one: a symbol reads as its name."
  def plain({:sym, name}), do: name
  def plain(value), do: value

  @doc "`plain/1`, but `false` reads as `nil`: an option that is absent."
  def string(false), do: nil
  def string(value), do: plain(value)

  @doc "A symbol, or a list of symbols, as plain values."
  def strings(value) when is_list(value), do: Enum.map(value, &plain/1)
  def strings(value), do: plain(value)

  @doc "The integer at the front of an argument list, or `nil`."
  def integer([n | _rest]) when is_integer(n), do: n
  def integer(_args), do: nil

  @doc "An alist pair reads as `[name | seq]`; a pair reads as `[name, seq]`."
  def seq([seq]), do: seq
  def seq(seq), do: seq

  @doc """
  The KEYS of MAP as the plist Scheme reads back: `:short_sha` is the
  symbol `short-sha`, and `nil` is `#f`.
  """
  def plist(map, keys) do
    Enum.flat_map(keys, fn key ->
      [{:sym, key |> Atom.to_string() |> String.replace("_", "-")}, Map.get(map, key) || false]
    end)
  end

  @doc "A header or parameter set as `{name, value}` pairs, names as strings."
  def pairs(map) when is_map(map) do
    for {key, value} <- map, do: {to_string(key), scalar(value)}
  end

  def pairs(list) when is_list(list) do
    Enum.flat_map(list, fn
      [key, value] -> [{to_string(key), scalar(value)}]
      {key, value} -> [{to_string(key), scalar(value)}]
      _pair -> []
    end)
  end

  def pairs(_other), do: []

  @doc "A header or parameter value as text."
  def scalar(value) when is_binary(value), do: value
  def scalar(value) when is_number(value), do: to_string(value)
  def scalar(value) when is_boolean(value), do: to_string(value)
  def scalar(value), do: value
end
