defmodule Compos.Core.TS do
  @moduledoc """
  Tree-sitter NIF bindings (native/compos_ts). Byte offsets throughout —
  matching Buffer. Languages: elixir, json, rust (growing).

  All functions degrade gracefully for unknown languages (empty/nil).
  """

  use Rustler, otp_app: :compos_core, crate: "compos_ts"

  @doc "Highlight spans: [{start, stop, scope}] from the grammar's query."
  def ts_highlight(_lang, _text), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Structural nav (op: forward|backward|up|down) -> byte pos or nil."
  def ts_nav(_lang, _text, _pos, _op), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The named node {kind, start, stop} and its neighbours. An empty kind
  means the smallest node covering the range; nested nodes can share a
  range, so the kind names which one the caller stands on.
  op: at | parent | child | next | prev | top -> {kind, start, stop} or nil.
  """
  def ts_node(_lang, _text, _kind, _start, _stop, _op), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Arbitrary query: [{capture, start, stop}]."
  def ts_query_nif(_lang, _text, _query), do: :erlang.nif_error(:nif_not_loaded)

  def ts_langs, do: :erlang.nif_error(:nif_not_loaded)

  @doc "dlopen a grammar library and register it: \"ok\" | \"error: ...\"."
  def ts_load_grammar(_name, _lib_path, _highlights), do: :erlang.nif_error(:nif_not_loaded)

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

  @doc "ts_node against the held tree — a walk, not a parse."
  def ts_state_node(_res, _text, _kind, _start, _stop, _op),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Every named child of one node: [{kind, start, stop}]."
  def ts_state_children(_res, _text, _kind, _start, _stop),
    do: :erlang.nif_error(:nif_not_loaded)
end
