defmodule Compos.Core.SchemeWarmup do
  @moduledoc false

  alias Compos.Core.Session

  # The catalog is complete when Session publishes its interpreter. Build the
  # immutable apropos rows and reconcile their vectors in a shared-world task:
  # application startup can finish, and a foreground query embeds only itself.
  def start_link(_opts) do
    Task.start_link(fn ->
      Process.sleep(50)

      # The embedding sync can call the network once per missing vector, so
      # the first boot after the catalog grows runs for minutes. The task is
      # temporary and owns its lane, so a long wait blocks nothing; a short
      # timeout kills the task and leaves the caches cold.
      Session.eval(
        """
        (begin
          (apropos--rows-cached)
          (apropos-sync-embeddings!))
        """,
        nil,
        300_000,
        {:system, :scheme_warmup}
      )
    end)
  end
end
