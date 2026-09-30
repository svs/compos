defmodule Compos.Ui.RopeSync do
  @moduledoc """
  The text sync for the browser's rope (predict.js, rope.wasm).

  In a window where Scheme turns on `predict-mode`, the client holds a rope
  of the buffer text. The client applies a typed character to its rope and
  paints it before the daemon answers. This module tells the client what the
  daemon holds, so the client can drop the edits the daemon ran and keep the
  rest.

  The first payload for a window carries the whole text. Each later payload
  carries one contiguous change from the text sent last, the buffer version,
  point, and `ack`: the last intent sequence number the daemon ran. The
  client sends that number with each intent. The daemon owns the text: when
  its text differs from a prediction, the client takes the daemon's text.
  """

  @doc """
  The payload for LEAF against SENT (the entry this module returned last for
  that window, or nil), and the entry to keep. The payload is nil when the
  client already holds everything that the payload would carry.
  """
  def payload(%{id: win, buffer: buffer, version: v, point: pt} = leaf, sent, ack) do
    text = leaf_text(leaf)
    entry = {buffer, v, pt, ack, text}

    payload =
      case sent do
        {^buffer, ^v, ^pt, ^ack, _} ->
          nil

        {^buffer, ^v, _, _, _} ->
          %{win: win, v: v, pt: pt, ack: ack}

        {^buffer, _, _, _, old} ->
          {at, del, ins} = delta(old, text)
          %{win: win, v: v, pt: pt, ack: ack, at: at, del: del, ins: ins}

        _ ->
          %{win: win, v: v, pt: pt, ack: ack, text: text}
      end

    {payload, entry}
  end

  @doc """
  The one contiguous replacement that turns OLD into NEW, as
  `{byte, deleted_bytes, inserted_text}`. Both ends stop on a UTF-8 char
  boundary, so the inserted text is always valid UTF-8.
  """
  def delta(old, new) when is_binary(old) and is_binary(new) do
    pre = :binary.longest_common_prefix([old, new]) |> back_to_char(new)
    old_rest = binary_part(old, pre, byte_size(old) - pre)
    new_rest = binary_part(new, pre, byte_size(new) - pre)
    suf = :binary.longest_common_suffix([old_rest, new_rest]) |> suffix_to_char(new_rest)
    del = byte_size(old_rest) - suf
    ins = binary_part(new_rest, 0, byte_size(new_rest) - suf)
    {pre, del, ins}
  end

  # a prefix that ends inside a char loses the char's leading bytes
  defp back_to_char(0, _bin), do: 0

  defp back_to_char(n, bin) when n >= byte_size(bin), do: n

  defp back_to_char(n, bin) do
    if continuation?(:binary.at(bin, n)), do: back_to_char(n - 1, bin), else: n
  end

  # a suffix that starts on a continuation byte gives that byte back
  defp suffix_to_char(0, _bin), do: 0

  defp suffix_to_char(n, bin) do
    if continuation?(:binary.at(bin, byte_size(bin) - n)),
      do: suffix_to_char(n - 1, bin),
      else: n
  end

  defp continuation?(byte), do: Bitwise.band(byte, 0xC0) == 0x80

  defp leaf_text(%{text: text}) when is_binary(text), do: text
  defp leaf_text(%{rope: %Compos.Core.Rope{} = rope}), do: Compos.Core.Rope.to_binary(rope)
  defp leaf_text(_), do: ""

  @doc "True when LEAF is a text window where Scheme turns on predict-mode."
  def predict?(%{type: :leaf} = leaf) do
    "predict-mode" in (Map.get(leaf, :minor_modes) || []) and
      Map.get(leaf, :read_only) != true and is_nil(Map.get(leaf, :render_mode))
  end

  def predict?(_), do: false
end
