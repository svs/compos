defmodule Aimax.Core.DocNif do
  @moduledoc false
  use Rustler, otp_app: :aimax_core, crate: "aimax_loro"

  def doc_new(_peer), do: :erlang.nif_error(:nif_not_loaded)
  def doc_open(_peer, _snapshot), do: :erlang.nif_error(:nif_not_loaded)
  def doc_register_actor(_d, _actor, _exclude, _max), do: :erlang.nif_error(:nif_not_loaded)

  def doc_insert(_d, _pos, _text), do: :erlang.nif_error(:nif_not_loaded)
  def doc_delete(_d, _pos, _len), do: :erlang.nif_error(:nif_not_loaded)
  def doc_update(_d, _text, _by_line), do: :erlang.nif_error(:nif_not_loaded)
  def doc_commit(_d, _origin, _msg, _ts), do: :erlang.nif_error(:nif_not_loaded)

  def doc_text(_d), do: :erlang.nif_error(:nif_not_loaded)
  def doc_len(_d), do: :erlang.nif_error(:nif_not_loaded)

  def doc_undo(_d, _actor), do: :erlang.nif_error(:nif_not_loaded)
  def doc_redo(_d, _actor), do: :erlang.nif_error(:nif_not_loaded)
  def doc_undo_count(_d, _actor), do: :erlang.nif_error(:nif_not_loaded)

  def doc_cursor(_d, _pos), do: :erlang.nif_error(:nif_not_loaded)
  def doc_cursor_pos(_d, _cursor), do: :erlang.nif_error(:nif_not_loaded)

  def doc_version(_d), do: :erlang.nif_error(:nif_not_loaded)
  def doc_export_snapshot(_d), do: :erlang.nif_error(:nif_not_loaded)
  def doc_export_updates(_d, _from), do: :erlang.nif_error(:nif_not_loaded)
  def doc_import(_d, _bytes), do: :erlang.nif_error(:nif_not_loaded)

  def doc_history(_d), do: :erlang.nif_error(:nif_not_loaded)
end
