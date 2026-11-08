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
  def print(l) when is_list(l), do: "(" <> items(l, &print/1) <> ")"

  def print({:closure, {req, opt, rest}, _, _}) do
    opt = if opt == [], do: [], else: ["&optional" | opt]
    rest = if rest, do: ["&rest", rest], else: []
    "#<procedure (#{Enum.join(req ++ opt ++ rest, " ")})>"
  end

  def print({:interposed, original, _}), do: "#<interposed " <> print(original) <> ">"
  def print({:builtin, name, _}), do: "#<builtin #{name}>"
  def print(other), do: inspect(other)

  def display(s) when is_binary(s), do: s
  def display(l) when is_list(l), do: "(" <> items(l, &display/1) <> ")"
  def display(other), do: print(other)

  # a dotted pair is an improper BEAM list: [a | b] prints as (a . b)
  defp items(l, f), do: l |> items(f, []) |> Enum.reverse() |> IO.iodata_to_binary()

  defp items([], _f, acc), do: acc
  defp items([x], f, acc), do: [f.(x) | acc]
  defp items([x | t], f, acc) when is_list(t), do: items(t, f, [" ", f.(x) | acc])
  defp items([x | t], f, acc), do: [f.(t), " . ", f.(x) | acc]
end
