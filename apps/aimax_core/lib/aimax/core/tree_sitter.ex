defmodule Aimax.Core.TreeSitter do
  @moduledoc """
  Tree-sitter binding — NOT YET IMPLEMENTED.

  Plan (mirrors the aimax Rust design, docs/LISP.md §7):

    * Rustler NIF crate (`native/aimax_ts`) wrapping tree-sitter, using dirty
      CPU schedulers for parses. Grammars compiled in: rust, elixir, markdown,
      json, plus the custom `tree-sitter-log` grammar (port from
      ../aimax/tree-sitter-log/grammar.js).
    * Each Buffer process owns its `tree` resource; on every mutation the
      buffer calls `edit/2` + `parse/3` for incremental re-parse and receives
      changed ranges, which feed the Reactor's `{:ts_query, ...}` matchers.

  API to implement:

    * `parse(text, lang)` -> {:ok, tree}
    * `edit(tree, %{start_byte:, old_end_byte:, new_end_byte:})` -> tree
    * `query(tree_or_text, query_src, lang)` -> [%{capture: name, range: {s, e}, text: t}]
    * `changed_ranges(old_tree, new_tree)` -> [{s, e}]
  """

  def parse(_text, _lang), do: {:error, :not_implemented}
  def query(_target, _query, _lang), do: {:error, :not_implemented}
end
