defmodule Compos.Core.SchemeWarmup do
  @moduledoc false

  alias Compos.Core.Session

  # Warm what the first use pays for, off the lanes that serve keys. The
  # apropos rows and their vectors are not here: tools.scm builds them once
  # on after-init-hook, when the catalog is complete.
  def start_link(_opts) do
    Task.start_link(fn ->
      Process.sleep(50)

      # The first model lookup decodes the bundled LLMDB snapshot, about a
      # second of CPU. A chat's first turn-end used to pay it on the chat's
      # own lane, in front of every keystroke queued there. Pay it here.
      Compos.Core.ModelCatalog.warm()

      # The task is temporary and owns its lane, so a long wait blocks
      # nothing.
      Session.eval(
        """
        (begin
          ;; the catalog snapshot Elixir reads for a reasoning lookup. Built
          ;; here, once, after the catalog is warm; rebuilt by a catalog install.
          (when (boundp 'model-rules-build!) (model-rules-build!)))
        """,
        nil,
        300_000,
        {:system, :scheme_warmup}
      )
    end)
  end
end
