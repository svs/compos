defmodule Aimax.Core.Terminal.Transcript do
  @moduledoc false

  defstruct mode: :text, utf8_carry: ""

  def new, do: %__MODULE__{}

  def feed(%__MODULE__{} = state, data) when is_binary(data) do
    {plain, mode} = scan(data, state.mode, [])
    {text, utf8_carry} = decode_utf8(state.utf8_carry <> plain)
    {text, %{state | mode: mode, utf8_carry: utf8_carry}}
  end

  def finish(%__MODULE__{} = state) do
    text = String.replace_invalid(state.utf8_carry, "�")
    {text, %{state | mode: :text, utf8_carry: ""}}
  end

  def sanitize(data) when is_binary(data) do
    {text, state} = feed(new(), data)
    {tail, _state} = finish(state)
    text <> tail
  end

  defp scan(<<>>, mode, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), mode}

  defp scan(<<27, rest::binary>>, :text, acc), do: scan(rest, :escape, acc)

  defp scan(<<byte, rest::binary>>, :text, acc)
       when byte in [9, 10] or (byte >= 32 and byte != 127),
       do: scan(rest, :text, [byte | acc])

  defp scan(<<_control, rest::binary>>, :text, acc), do: scan(rest, :text, acc)

  defp scan(<<27, rest::binary>>, :escape, acc), do: scan(rest, :escape, acc)
  defp scan(<<?[, rest::binary>>, :escape, acc), do: scan(rest, :csi, acc)
  defp scan(<<?], rest::binary>>, :escape, acc), do: scan(rest, :osc, acc)

  defp scan(<<byte, rest::binary>>, :escape, acc) when byte in [?P, ?X, ?^, ?_],
    do: scan(rest, :control_string, acc)

  defp scan(<<byte, rest::binary>>, :escape, acc) when byte in 32..47,
    do: scan(rest, :escape_intermediate, acc)

  defp scan(<<_final, rest::binary>>, :escape, acc), do: scan(rest, :text, acc)

  defp scan(<<byte, rest::binary>>, :escape_intermediate, acc) when byte in 32..47,
    do: scan(rest, :escape_intermediate, acc)

  defp scan(<<_final, rest::binary>>, :escape_intermediate, acc), do: scan(rest, :text, acc)

  defp scan(<<27, rest::binary>>, :csi, acc), do: scan(rest, :escape, acc)

  defp scan(<<byte, rest::binary>>, :csi, acc) when byte in 64..126,
    do: scan(rest, :text, acc)

  defp scan(<<_byte, rest::binary>>, :csi, acc), do: scan(rest, :csi, acc)

  defp scan(<<7, rest::binary>>, :osc, acc), do: scan(rest, :text, acc)
  defp scan(<<27, rest::binary>>, :osc, acc), do: scan(rest, :osc_escape, acc)
  defp scan(<<_byte, rest::binary>>, :osc, acc), do: scan(rest, :osc, acc)

  defp scan(<<92, rest::binary>>, :osc_escape, acc), do: scan(rest, :text, acc)
  defp scan(<<27, rest::binary>>, :osc_escape, acc), do: scan(rest, :osc_escape, acc)
  defp scan(<<_byte, rest::binary>>, :osc_escape, acc), do: scan(rest, :osc, acc)

  defp scan(<<27, rest::binary>>, :control_string, acc),
    do: scan(rest, :control_string_escape, acc)

  defp scan(<<_byte, rest::binary>>, :control_string, acc),
    do: scan(rest, :control_string, acc)

  defp scan(<<92, rest::binary>>, :control_string_escape, acc),
    do: scan(rest, :text, acc)

  defp scan(<<27, rest::binary>>, :control_string_escape, acc),
    do: scan(rest, :control_string_escape, acc)

  defp scan(<<_byte, rest::binary>>, :control_string_escape, acc),
    do: scan(rest, :control_string, acc)

  defp decode_utf8(data) do
    case :unicode.characters_to_binary(data, :utf8, :utf8) do
      text when is_binary(text) ->
        {text, ""}

      {:incomplete, text, rest} ->
        {text, rest}

      {:error, text, <<_invalid, rest::binary>>} ->
        {tail, carry} = decode_utf8(rest)
        {text <> "�" <> tail, carry}
    end
  end
end
