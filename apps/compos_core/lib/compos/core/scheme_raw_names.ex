defmodule Compos.Core.SchemeRawNames do
  @moduledoc """
  The raw name of every primitive the Scheme editor wraps.

  `editor.scm` wraps a primitive by defining a Scheme function under the
  public name, and calling the primitive under a second name. Scheme used
  to make that second name itself, with `(define raw-x x)` above the
  wrapper. A whole-file reload evaluated that capture again, when the
  public name already held the wrapper: the wrapper then called itself, and
  the next call recursed until the heap bound killed the job. On 2026-09-10
  `define-command--raw` took that path, and the daemon could define no
  command again.

  Nothing in Scheme repaired that daemon. The capture held the only
  reference to the primitive, and `Scheme.rebind_primitives/2` reaches a
  primitive only inside a `{:builtin, name, fun}` tuple, so the poisoned
  name held a closure and the primitive was gone. A restart was the only
  repair, and this editor is meant to run for weeks.

  So Elixir owns the raw name. Both registration modules add these names to
  their own primitive map, which gives three properties Scheme cannot:

    * no Scheme form captures a primitive, so no reload can point a wrapper
      at itself,
    * `rebind_primitives` keeps the raw name current across a code swap,
      because it is a primitive like any other,
    * `M-x reload-scheme` registers it again, so a raw name that somehow
      goes wrong is repaired in the running daemon.

  `add/1` skips a name whose target the caller's map does not hold, so
  each module contributes only its own primitives. The test
  `scheme_raw_names_test.exs` checks that every name here resolves in
  exactly one module.
  """

  # RAW NAME => the primitive it names. The Scheme wrapper under the
  # primitive's own name lives in editor.scm.
  @wrapped %{
    "define-command--raw" => "define-command",
    "builtin-load" => "load",
    "undefine-command--raw" => "undefine-command",
    "minibuffer-read*--raw" => "minibuffer-read*",
    "raw-buffer-create" => "buffer-create",
    "raw-find-file" => "find-file",
    "local-list-dir" => "list-dir",
    "local-directory-entries" => "directory-entries",
    "local-file-stat" => "file-stat",
    "local-delete-file!" => "delete-file!",
    "local-make-directory!" => "make-directory!",
    "local-rename-file!" => "rename-file!",
    "local-copy-file!" => "copy-file!",
    "local-trash-file!" => "trash-file!",
    "local-set-file-mode!" => "set-file-mode!",
    "local-touch-file!" => "touch-file!",
    "local-make-symlink!" => "make-symlink!",
    "builtin-window-tree-set!" => "window-tree-set!",
    "builtin-delete-other-windows!" => "delete-other-windows!",
    "builtin-split-window!" => "split-window!",
    "builtin-delete-window!" => "delete-window!",
    "builtin-delete-window-id!" => "delete-window-id!"
  }

  @doc "RAW NAME => wrapped primitive name, for every name the editor wraps."
  def wrapped, do: @wrapped

  @doc """
  PRIMITIVES plus one entry per raw name whose target PRIMITIVES holds.

  The raw name gets the same fun as the primitive, so both names are one
  primitive with two spellings.
  """
  def add(entries) do
    Enum.reduce(@wrapped, entries, fn {raw, target}, acc ->
      case Compos.Scheme.Prim.fun(entries, target) do
        nil -> acc
        fun -> Map.put(acc, {raw, doc(raw, target)}, fun)
      end
    end)
  end

  defp doc(raw, target),
    do: "(#{raw} ...) — the #{target} primitive itself; editor.scm wraps #{target} in Scheme."
end
