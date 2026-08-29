defmodule Compos.Scheme.Printer do
  @moduledoc "Scheme value -> string. `print` is `write`-style, `display` is human-style."

  def print(true), do: "#t"
  def print(false), do: "#f"
  def print(:void), do: ""
  def print({:sym, s}), do: s
  # printable_limit: inspect truncates strings past 4096 bytes by default —
  # print is the RPC wire format ("eval is the API"), so it must be faithful
  def print(s) when is_binary(s), do: inspect(s, printable_limit: :infinity)
  def print(i) when is_integer(i), do: Integer.to_string(i)
  def print(f) when is_float(f), do: Float.to_string(f)
  def print(l) when is_list(l), do: "(" <> Enum.map_join(l, " ", &print/1) <> ")"
  def print({:closure, {req, opt, rest}, _, _}) do
    opt = if opt == [], do: [], else: ["&optional" | opt]
    rest = if rest, do: ["&rest", rest], else: []
    "#<procedure (#{Enum.join(req ++ opt ++ rest, " ")})>"
  end
  def print({:builtin, name, _}), do: "#<builtin #{name}>"
  def print(other), do: inspect(other)

  def display(s) when is_binary(s), do: s
  def display(l) when is_list(l), do: "(" <> Enum.map_join(l, " ", &display/1) <> ")"
  def display(other), do: print(other)
end
