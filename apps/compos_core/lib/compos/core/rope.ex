defmodule Compos.Core.Rope do
  @moduledoc """
  Immutable rope backed by ropey (`native/compos_rope`) — the rope under the
  Helix editor: balanced by construction, with O(log n) byte<->line lookup.
  **Byte offsets** throughout — matches tree-sitter's edit API; callers own
  grapheme/codepoint concerns.

  Every edit returns a new handle sharing structure with the old one, so
  undo snapshots stay free. A byte offset inside a multi-byte char floors
  to that char's start.
  """

  alias Compos.Core.RopeNif

  defstruct [:res, :size]

  def new(text \\ "") when is_binary(text),
    do: %__MODULE__{res: RopeNif.rope_new(text), size: Kernel.byte_size(text)}

  def to_binary(%__MODULE__{res: res}), do: RopeNif.rope_to_binary(res)

  # size is mirrored Elixir-side so hot-path bounds checks skip the NIF hop
  def byte_size(%__MODULE__{size: size}), do: size

  # sizes re-read from the NIF after edits: a mid-char offset floors to the
  # char boundary, so arithmetic mirroring could drift from the truth
  def insert(%__MODULE__{res: res, size: size} = rope, pos, text) when pos >= 0 do
    if pos > size, do: raise(ArgumentError, "insert out of bounds")
    res = RopeNif.rope_insert(res, pos, text)
    %{rope | res: res, size: RopeNif.rope_len_bytes(res)}
  end

  def delete(%__MODULE__{res: res, size: size} = rope, pos, len) when pos >= 0 and len >= 0 do
    if pos + len > size, do: raise(ArgumentError, "delete out of bounds")
    res = RopeNif.rope_delete(res, pos, len)
    %{rope | res: res, size: RopeNif.rope_len_bytes(res)}
  end

  def slice(%__MODULE__{res: res}, pos, len), do: RopeNif.rope_slice(res, pos, len)

  @doc "Total lines (newline count + 1, Emacs semantics). O(1)."
  def line_count(%__MODULE__{res: res}), do: RopeNif.rope_line_count(res)

  @doc "0-based line index containing the byte offset. O(log n)."
  def byte_to_line(%__MODULE__{res: res}, pos), do: RopeNif.rope_byte_to_line(res, pos)

  @doc "Byte offset of a 0-based line's start (line_count => end of text). O(log n)."
  def line_to_byte(%__MODULE__{res: res}, line), do: RopeNif.rope_line_to_byte(res, line)
end
