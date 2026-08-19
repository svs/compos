defmodule Aimax.Ui.Telemetry do
  @moduledoc """
  Metrics for the live dashboard at `/dashboard`.

  The poller samples the VM every 10 seconds. The dashboard charts
  these metrics on its Home and Metrics pages. The Processes page
  needs no metrics; it reads the VM directly.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: [], period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # every HTTP request and LiveView mount, as a duration
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.mount.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.live_view.handle_event.stop.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # the Session is the editor's single writer: a slow op here is a
      # frozen editor. The op tag says which lane blocked.
      summary("aimax.session.op.duration", tags: [:op], unit: :millisecond),

      # the VM: a run queue that grows shows a scheduler that falls behind
      summary("vm.memory.total", unit: {:byte, :megabyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),
      summary("vm.system_counts.process_count")
    ]
  end
end
