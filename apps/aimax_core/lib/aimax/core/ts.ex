defmodule Aimax.Core.TS do
  @moduledoc """
  Tree-sitter NIF bindings (native/aimax_ts). Byte offsets throughout —
  matching Buffer. Languages: elixir, json, rust (growing).

  All functions degrade gracefully for unknown languages (empty/nil).
  """

  use Rustler, otp_app: :aimax_core, crate: "aimax_ts"

  @doc "Highlight spans: [{start, stop, scope}] from the grammar's query."
  def ts_highlight(_lang, _text), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Structural nav (op: forward|backward|up|down) -> byte pos or nil."
  def ts_nav(_lang, _text, _pos, _op), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Arbitrary query: [{capture, start, stop}]."
  def ts_query_nif(_lang, _text, _query), do: :erlang.nif_error(:nif_not_loaded)

  def ts_langs, do: :erlang.nif_error(:nif_not_loaded)

  # stateful parser resource (incremental fontification; owned by a Buffer)
  @doc "Parser resource for a language, or nil if unknown."
  def ts_state_new(_lang), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Feed one edit into the held tree (byte offsets + row/byte-col points)."
  def ts_state_edit(_res, _sb, _oeb, _neb, _sr, _sc, _oer, _oec, _ner, _nec),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Drop the held tree — next highlight is a full reparse."
  def ts_state_reset(_res), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Parse (incrementally if possible) and return highlight spans."
  def ts_state_highlight(_res, _text), do: :erlang.nif_error(:nif_not_loaded)
end
