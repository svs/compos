defmodule Compos.Core.SchemeWarmup do
  @moduledoc false

  alias Compos.Core.Session

  # The catalog is complete when Session publishes its interpreter. Build the
  # immutable apropos rows and reconcile their vectors in a shared-world task:
  # application startup can finish, and a foreground query embeds only itself.
  def start_link(_opts) do
    Task.start_link(fn ->
      Process.sleep(50)

      Session.eval(
        """
        (begin
          (apropos--rows-cached)
          (apropos-sync-embeddings!))
        """,
        nil,
        5_000,
        {:system, :scheme_warmup}
      )
    end)
  end
end
