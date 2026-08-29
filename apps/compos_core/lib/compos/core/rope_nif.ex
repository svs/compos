defmodule Compos.Core.RopeNif do
  @moduledoc false
  use Rustler, otp_app: :compos_core, crate: "compos_rope"

  def rope_new(_text), do: :erlang.nif_error(:nif_not_loaded)
  def rope_len_bytes(_r), do: :erlang.nif_error(:nif_not_loaded)
  def rope_to_binary(_r), do: :erlang.nif_error(:nif_not_loaded)
  def rope_insert(_r, _pos, _text), do: :erlang.nif_error(:nif_not_loaded)
  def rope_delete(_r, _pos, _len), do: :erlang.nif_error(:nif_not_loaded)
  def rope_slice(_r, _pos, _len), do: :erlang.nif_error(:nif_not_loaded)
  def rope_line_count(_r), do: :erlang.nif_error(:nif_not_loaded)
  def rope_byte_to_line(_r, _pos), do: :erlang.nif_error(:nif_not_loaded)
  def rope_line_to_byte(_r, _line), do: :erlang.nif_error(:nif_not_loaded)
end
