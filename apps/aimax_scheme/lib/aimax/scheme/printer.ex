defmodule Aimax.Scheme.Printer do
  @moduledoc "Scheme value -> string. `print` is `write`-style, `display` is human-style."

  @char_names %{
    0 => "nul",
    7 => "alarm",
    8 => "backspace",
    ?\t => "tab",
    ?\n => "newline",
    ?\r => "return",
    27 => "escape",
    ?\s => "space",
    127 => "delete"
  }

  def print(true), do: "#t"
  def print(false), do: "#f"
  def print(:void), do: ""
  def print({:sym, s}), do: s
  def print({:char, cp}), do: "#\\" <> char_name(cp)
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

  def print({:builtin, name, _}), do: "#<builtin #{name}>"
  def print(other), do: inspect(other)

  def display({:char, cp}), do: <<cp::utf8>>
  def display(s) when is_binary(s), do: s
  def display(l) when is_list(l), do: "(" <> items(l, &display/1) <> ")"
  def display(other), do: print(other)

  defp char_name(cp), do: Map.get(@char_names, cp, <<cp::utf8>>)

  # an improper list prints its tail after a dot: (1 . 2), (1 2 . 3)
  defp items([], _f), do: ""
  defp items([x], f), do: f.(x)
  defp items([x | rest], f) when is_list(rest), do: f.(x) <> " " <> items(rest, f)
  defp items([x | tail], f), do: f.(x) <> " . " <> f.(tail)
end
