defmodule Compos.Core.Cron do
  @moduledoc """
  The clock under `scheme/packages/cron.scm`. Quantum owns the timer and
  the cron grammar: one scheduler, one job per name, and nothing runs
  between two due times.

  A due job does one thing: it appends `fired` to the topic `cron:NAME` of
  the event log. What the job means is Scheme's. A workflow over `cron:*`
  runs it, so a run is retried, recorded, and off the keystroke lane.

  The log is also the record. The newest event on `cron:NAME` tells when
  the job last ran, and that is what cron.scm reads to catch up a run the
  daemon missed while it was down.

  Times are local, in `zone/0`, unless a job names its own zone.
  """
  use Quantum, otp_app: :compos_core

  alias Compos.Core.Events.Log
  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler, as: Dates

  @doc "Run or replace the job NAME on the cron SPEC. Answer its next run in unix seconds."
  def schedule(name, spec, zone \\ zone()) do
    expr = parse!(spec)
    job = job_name(name)
    delete_job(job)

    new_job()
    |> Quantum.Job.set_name(job)
    |> Quantum.Job.set_schedule(expr)
    |> Quantum.Job.set_timezone(zone)
    |> Quantum.Job.set_overlap(false)
    |> Quantum.Job.set_task({__MODULE__, :fire, [name, spec]})
    |> add_job()

    next(spec, zone)
  end

  @doc "Stop the job NAME."
  def unschedule(name), do: delete_job(job_name(name))

  @doc "The names of the scheduled jobs."
  def names do
    for {job, _} <- jobs(), "cron:" <> name <- [Atom.to_string(job)], do: name
  end

  @doc "True when the scheduler runs. A daemon that booted before cron existed has none."
  def running?, do: Code.ensure_loaded?(Quantum) and GenServer.whereis(__job_broadcaster__()) != nil

  @doc """
  Hand cron.scm its jobs. The packages load before the scheduler and the
  workflows start, so cron.scm defines its workflow and schedules the jobs
  of cron-file here, once both are up.
  """
  def boot do
    Compos.Core.Session.call_named("cron--boot!", [], nil, 60_000, {:system, :cron_boot})
  end

  @doc "The job's run: one event on `cron:NAME`. Quantum calls this when NAME is due."
  def fire(name, spec) do
    Log.append("cron:" <> name, {:sym, "fired"}, [{:sym, "name"}, name, {:sym, "spec"}, spec])
  end

  @doc "The next time SPEC is due after now, in unix seconds."
  def next(spec, zone \\ zone()) do
    {:ok, at} = Dates.get_next_run_date(parse!(spec), now(zone))
    unix(at, zone)
  end

  @doc "The last time SPEC was due, now or before, in unix seconds."
  def previous(spec, zone \\ zone()) do
    {:ok, at} = Dates.get_previous_run_date(parse!(spec), now(zone))
    unix(at, zone)
  end

  @doc "The local time zone: $TZ, else the zone /etc/localtime links to, else UTC."
  def zone do
    with tz when tz in [nil, ""] <- System.get_env("TZ"),
         {:ok, link} <- File.read_link("/etc/localtime"),
         [_, tz] <- String.split(link, "zoneinfo/", parts: 2) do
      tz
    else
      tz when is_binary(tz) and tz != "" -> tz
      _ -> "Etc/UTC"
    end
  end

  def primitives do
    %{
      {"cron-schedule!",
       "(cron-schedule! NAME SPEC [ZONE]) — run or replace the job NAME on the cron SPEC; answer its next run in unix seconds."} =>
        fn [name, spec | rest] -> schedule(name, spec, zone_arg(rest)) end,
      {"cron-unschedule!", "(cron-unschedule! NAME) — stop the job NAME."} =>
        fn [name] ->
          unschedule(name)
          :void
        end,
      {"cron-scheduled", "(cron-scheduled) — the names of the jobs the scheduler holds."} =>
        fn [] -> names() end,
      {"cron-running?", "(cron-running?) — #t when the scheduler runs; a daemon that booted before cron has none."} =>
        fn [] -> running?() end,
      {"cron-next", "(cron-next SPEC [ZONE]) — the next time SPEC is due, in unix seconds; an error when SPEC does not parse."} =>
        fn [spec | rest] -> next(spec, zone_arg(rest)) end,
      {"cron-previous", "(cron-previous SPEC [ZONE]) — the last time SPEC was due, now or before, in unix seconds."} =>
        fn [spec | rest] -> previous(spec, zone_arg(rest)) end,
      {"cron-zone", "(cron-zone) — the local time zone cron times are read in."} =>
        fn [] -> zone() end
    }
  end

  defp job_name(name), do: String.to_atom("cron:" <> name)

  defp zone_arg([zone | _]) when is_binary(zone) and zone != "", do: zone
  defp zone_arg(_), do: zone()

  defp parse!(spec) do
    case Parser.parse(spec) do
      {:ok, expr} -> expr
      {:error, reason} -> raise ArgumentError, "cron: " <> spec <> ": " <> reason
    end
  end

  defp now(zone), do: zone |> DateTime.now!() |> DateTime.to_naive()

  # a wall time a clock change skips runs at the first time after it; one
  # it repeats runs at the first of the two
  defp unix(naive, zone) do
    case DateTime.from_naive(naive, zone) do
      {:ok, at} -> DateTime.to_unix(at)
      {:ambiguous, first, _} -> DateTime.to_unix(first)
      {:gap, _, after_gap} -> DateTime.to_unix(after_gap)
    end
  end
end
