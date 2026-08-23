defmodule Aimax.Core.SchemeWarmup do
  @moduledoc false

  alias Aimax.Core.Session

  # The catalog is complete when Session publishes its interpreter. Build the
  # immutable apropos rows in a shared-world task: application startup can
  # finish, and the first agent does not inherit the lazy-build bill.
  def start_link(_opts) do
    Task.start_link(fn ->
      Process.sleep(50)

      Session.eval(
        """
        (task-run!
          (lambda () (begin (apropos "__aimax_catalog_warmup__") #t))
          (lambda (ok value) #t)
          30000)
        """,
        nil,
        5_000,
        {:system, :scheme_warmup}
      )
    end)
  end
end
