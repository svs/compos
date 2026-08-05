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
end
