defmodule Aimax.Core.Doc do
  @moduledoc """
  A buffer's Loro document: its history, its undo stacks, and its cursors.
  See `docs/PROVENANCE-CRDT.md`.

  **Byte offsets** throughout, matching `Aimax.Core.Rope` and tree-sitter.

  This is not a read path. The rope stays the working representation and the
  line index; the document answers who wrote what, and merges concurrent work.

  Two rules the Phase 0 gate proved, both load-bearing:

  - The actor rides in the commit message. A Loro change carries no origin
    field, so an origin does not survive an export.
  - Every actor's undo manager excludes the `undo` origin. An undo is itself a
    change, so without the exclusion one actor's undo lands on another actor's
    stack, and that actor's next undo restores what was just removed.

  Unlike `Aimax.Core.Rope`, a document is a mutable handle. Every edit mutates
  the same resource, so a document cannot be an undo snapshot.
  """

  alias Aimax.Core.DocNif

  defstruct [:res, :peer]

  @default_undo_steps 500

  @doc """
  A new empty document for a replica. `peer` names the replica, not the actor:
  a human and an agent editing the same buffer share it, and the commit message
  tells them apart.
  """
  def new(peer) when is_integer(peer) and peer >= 0,
    do: %__MODULE__{res: DocNif.doc_new(peer), peer: peer}

  @doc "Reopen a document from `export_snapshot/1` bytes."
  def open(peer, snapshot) when is_integer(peer) and is_binary(snapshot) do
    case DocNif.doc_open(peer, snapshot) do
      res when is_reference(res) -> {:ok, %__MODULE__{res: res, peer: peer}}
      other -> other
    end
  end

  @doc """
  Register an actor that can undo, before its first edit. A manager records
  only what happens after it exists.

  `exclude` lists the origin prefixes this actor must not undo. Pass the other
  actors: a human excludes `["agent"]`. The `undo` origin is always excluded.
  """
  def register_actor(%__MODULE__{res: res}, actor, exclude \\ [], max_steps \\ @default_undo_steps)
      when is_binary(actor) and is_list(exclude) do
    DocNif.doc_register_actor(res, actor, exclude, max_steps)
  end

  # ------------------------------------------------------------- mutation

  @doc "Insert at a byte offset. Returns the new byte length."
  def insert(%__MODULE__{res: res}, pos, text) when pos >= 0 and is_binary(text),
    do: DocNif.doc_insert(res, pos, text)

  @doc "Delete `len` bytes at a byte offset. Returns the new byte length."
  def delete(%__MODULE__{res: res}, pos, len) when pos >= 0 and len >= 0,
    do: DocNif.doc_delete(res, pos, len)

  @doc """
  Replace the whole text, emitting the minimal operations. For a caller that
  knows the result but not the edit, such as desktop restore.

  Loro's character diff slows past about 50,000 characters, so anything larger
  goes line by line.
  """
  def update(%__MODULE__{res: res}, text) when is_binary(text),
    do: DocNif.doc_update(res, text, Kernel.byte_size(text) > 50_000)

  @doc """
  Close the pending change.

  `msg` is durable and carries the actor. `origin` is the live label the undo
  managers filter on, so it must match the prefixes given to `register_actor/4`.
  """
  def commit(%__MODULE__{res: res}, origin, msg, timestamp \\ nil)
      when is_binary(origin) and is_binary(msg) do
    DocNif.doc_commit(res, origin, msg, timestamp || System.system_time(:second))
  end

  # ----------------------------------------------------------------- read

  @doc "The whole text. O(n), and not the buffer's read path."
  def text(%__MODULE__{res: res}), do: DocNif.doc_text(res)

  def byte_size(%__MODULE__{res: res}), do: DocNif.doc_len(res)

  # ----------------------------------------------------------------- undo

  @doc "Undo one change by `actor`. Returns whether anything was undone."
  def undo(%__MODULE__{res: res}, actor), do: DocNif.doc_undo(res, actor)

  def redo(%__MODULE__{res: res}, actor), do: DocNif.doc_redo(res, actor)

  @doc "`{undo_count, redo_count}` for one actor."
  def undo_count(%__MODULE__{res: res}, actor), do: DocNif.doc_undo_count(res, actor)

  # -------------------------------------------------------------- cursors

  @doc """
  An opaque cursor over a byte offset. It survives concurrent edits, so an
  agent that reads a range now can edit it correctly later.

  Resolving costs far more than an edit, so cache the result and resolve on
  change, never per access.
  """
  def cursor(%__MODULE__{res: res}, pos) when pos >= 0, do: DocNif.doc_cursor(res, pos)

  def cursor_pos(%__MODULE__{res: res}, cursor) when is_binary(cursor),
    do: DocNif.doc_cursor_pos(res, cursor)

  # --------------------------------------------------- export and import

  @doc "The current version, for `export_updates/2`."
  def version(%__MODULE__{res: res}), do: DocNif.doc_version(res)

  @doc "Full state and history, for a checkpoint."
  def export_snapshot(%__MODULE__{res: res}), do: DocNif.doc_export_snapshot(res)

  @doc "Everything since `from`. The same bytes go to disk and to a peer."
  def export_updates(%__MODULE__{res: res}, from) when is_binary(from),
    do: DocNif.doc_export_updates(res, from)

  @doc """
  Import bytes another replica wrote. Returns the new byte length, because the
  caller must rebuild its rope from the result.
  """
  def import(%__MODULE__{res: res}, bytes) when is_binary(bytes),
    do: DocNif.doc_import(res, bytes)

  # -------------------------------------------------------------- history

  @doc """
  Every change, oldest first, as
  `%{peer:, counter:, lamport:, timestamp:, message:}`. The message carries the
  actor, so this is the attribution record.
  """
  def history(%__MODULE__{res: res}) do
    res
    |> DocNif.doc_history()
    |> Enum.map(fn {peer, counter, lamport, timestamp, message} ->
      %{peer: peer, counter: counter, lamport: lamport, timestamp: timestamp, message: message}
    end)
  end
end
