# Stale checkpoints in the shared test home slow every catalog read; see
# apps/compos_core/test/test_helper.exs. Each app runs in its own VM, so each
# one clears the directory it would otherwise leave behind.
case Application.get_env(:compos_core, :home) do
  home when is_binary(home) -> File.rm_rf!(Path.join(home, "buffers"))
  _ -> :ok
end

# This run's home, socket and desktop file go when the VM exits.
if Code.ensure_loaded?(Compos.TestRun), do: Compos.TestRun.clean_at_exit()

defmodule Compos.Ui.PreviewMarkup do
  @moduledoc """
  A preview page without its source bookkeeping. Every element names its
  byte range and every run of text sits in a span that names its first
  byte. A test that reads the page as a reader sees it removes both.
  """

  def shown(html) do
    html
    |> String.replace(~r/ data-(?:src|s)="[^"]*"/, "")
    |> String.replace(~r/<span class="s">(.*?)<\/span>/s, "\\1")
  end

  @doc "The markdown preview of TEXT, as `shown/1` answers it."
  def preview(text, point, mark \\ nil, overlays \\ [], opts \\ []),
    do:
      shown(
        Compos.Ui.EditorLive.preview_doc(
          "markdown",
          text,
          point,
          mark,
          %{},
          false,
          overlays,
          opts
        )
      )
end

ExUnit.start()

# UI agent fixtures must not create worktrees of the repository under test.
{:ok, _} =
  Compos.Core.Session.eval("(customize-set! 'agent-worktree-isolation #f)")
