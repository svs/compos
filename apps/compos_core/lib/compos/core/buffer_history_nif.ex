defmodule Compos.Core.BufferHistoryNif do
  @moduledoc false
  use Rustler, otp_app: :compos_core, crate: "compos_loro"

  def history_new(_peer), do: :erlang.nif_error(:nif_not_loaded)
  def history_open(_peer, _snapshot), do: :erlang.nif_error(:nif_not_loaded)
  def history_register_actor(_d, _actor, _exclude, _max), do: :erlang.nif_error(:nif_not_loaded)
  def history_has_actor(_d, _actor), do: :erlang.nif_error(:nif_not_loaded)
  def history_set_peer(_d, _peer), do: :erlang.nif_error(:nif_not_loaded)

  def history_insert(_d, _pos, _text), do: :erlang.nif_error(:nif_not_loaded)
  def history_delete(_d, _pos, _len), do: :erlang.nif_error(:nif_not_loaded)
  def history_update(_d, _text, _by_line), do: :erlang.nif_error(:nif_not_loaded)
  def history_commit(_d, _origin, _msg, _ts), do: :erlang.nif_error(:nif_not_loaded)

  def history_text(_d), do: :erlang.nif_error(:nif_not_loaded)
  def history_len(_d), do: :erlang.nif_error(:nif_not_loaded)

  def history_undo(_d, _actor), do: :erlang.nif_error(:nif_not_loaded)
  def history_redo(_d, _actor), do: :erlang.nif_error(:nif_not_loaded)
  def history_undo_count(_d, _actor), do: :erlang.nif_error(:nif_not_loaded)

  def history_cursor(_d, _pos), do: :erlang.nif_error(:nif_not_loaded)
  def history_cursor_pos(_d, _cursor), do: :erlang.nif_error(:nif_not_loaded)

  def history_version(_d), do: :erlang.nif_error(:nif_not_loaded)
  def history_export_snapshot(_d), do: :erlang.nif_error(:nif_not_loaded)
  def history_export_updates(_d, _from), do: :erlang.nif_error(:nif_not_loaded)
  def history_export_all(_d), do: :erlang.nif_error(:nif_not_loaded)
  def history_import(_d, _bytes), do: :erlang.nif_error(:nif_not_loaded)

  def history_changes(_d), do: :erlang.nif_error(:nif_not_loaded)
end
