defmodule JidoHpc.Sensors.SlurmJobSensor do
  @moduledoc """
  Polls `JidoHpc.Slurm.CLI.squeue/1` (and `sacct/2` once a job leaves the
  queue) and emits `Jido.Signal`s when a tracked job changes state.

  ## Why a sensor

  Slurm jobs run for minutes to days. Blocking on `squeue` polls inside an
  Action would tie up the agent's reasoning loop and miss tool calls. A
  sensor runs outside the action path: actions submit and return; the
  sensor wakes the agent only when something interesting happens.

  ## Tracked jobs

  Submit either pushes a job into the sensor (`track/2`) — typically right
  after `Slurm.Submit` returns a job id — or the sensor learns about the
  job at startup via `tracked_jobs:` in the start opts. Untracked jobs are
  ignored, even if they appear in `squeue`; the goal is to surface state
  changes the agent cares about, not every cluster event.

  ## Emitted signals

  Built via `Jido.Signal.new!/1` (when available) and dispatched via the
  configured signal bus. Topic format:

      slurm.job.<state>           # state in [completed, failed, timeout, oom,
                                  #            cancelled, node_fail, preempted]
      slurm.job.transition         # any non-terminal state change

  Payload: `%{job: %JidoHpc.Slurm.Job{}, previous_state: atom()}`.

  Once a job reaches a terminal state, the sensor untracks it.

  ## Polling

  `:poll_interval_ms` (default 10_000) controls poll cadence. A jittered
  +/-10% is added to avoid lock-step polls across multiple sensors.
  """

  use GenServer

  alias JidoHpc.Slurm.{CLI, Job}
  require Logger

  @default_poll 10_000
  @default_jitter_pct 10

  @type opts :: [
          name: GenServer.name(),
          poll_interval_ms: pos_integer(),
          tracked_jobs: [String.t()],
          dispatch: (atom(), map() -> any())
        ]

  # ---- Public API -------------------------------------------------------

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Begin tracking `job_id` (typically called from `Slurm.Submit`)."
  @spec track(GenServer.server(), String.t(), Job.t() | nil) :: :ok
  def track(server \\ __MODULE__, job_id, job \\ nil) when is_binary(job_id) do
    GenServer.cast(server, {:track, job_id, job})
  end

  @doc "Stop tracking `job_id`."
  @spec untrack(GenServer.server(), String.t()) :: :ok
  def untrack(server \\ __MODULE__, job_id) when is_binary(job_id) do
    GenServer.cast(server, {:untrack, job_id})
  end

  @doc "Return the current map of tracked jobs (id => %Job{})."
  @spec tracked(GenServer.server()) :: %{String.t() => Job.t()}
  def tracked(server \\ __MODULE__) do
    GenServer.call(server, :tracked)
  end

  @doc "Force a poll cycle now (mainly for tests)."
  @spec poll_now(GenServer.server()) :: :ok
  def poll_now(server \\ __MODULE__) do
    GenServer.call(server, :poll_now)
  end

  # ---- GenServer --------------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :poll_interval_ms, @default_poll)
    dispatch = Keyword.get(opts, :dispatch, &default_dispatch/2)
    initial = Keyword.get(opts, :tracked_jobs, []) |> Enum.map(&{&1, Job.new(&1)}) |> Map.new()

    state = %{
      jobs: initial,
      interval: interval,
      dispatch: dispatch,
      timer: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_cast({:track, id, nil}, state) do
    jobs = Map.put_new(state.jobs, id, Job.new(id))
    {:noreply, %{state | jobs: jobs}}
  end

  def handle_cast({:track, id, %Job{} = job}, state) do
    {:noreply, %{state | jobs: Map.put(state.jobs, id, job)}}
  end

  def handle_cast({:untrack, id}, state) do
    {:noreply, %{state | jobs: Map.delete(state.jobs, id)}}
  end

  @impl true
  def handle_call(:tracked, _from, state), do: {:reply, state.jobs, state}

  def handle_call(:poll_now, _from, state) do
    {:reply, :ok, do_poll(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    {:noreply, schedule(do_poll(state))}
  end

  # ---- Polling logic ----------------------------------------------------

  defp do_poll(%{jobs: jobs} = state) when map_size(jobs) == 0, do: state

  defp do_poll(state) do
    new_jobs =
      Enum.reduce(state.jobs, %{}, fn {id, job}, acc ->
        case refresh(id, job) do
          {:ok, updated, transitioned?} ->
            if transitioned?, do: emit(state.dispatch, updated, job.state)

            if Job.terminal?(updated),
              do: acc,
              else: Map.put(acc, id, updated)

          {:error, reason} ->
            Logger.debug("SlurmJobSensor: refresh #{id} failed: #{inspect(reason)}")
            Map.put(acc, id, job)
        end
      end)

    %{state | jobs: new_jobs}
  end

  defp refresh(id, job) do
    case CLI.squeue(job: id) do
      {:ok, [%{} = row | _]} ->
        {next, transitioned?} = Job.update(job, row)
        {:ok, next, transitioned?}

      {:ok, []} ->
        # Job left the queue — pull final state from sacct.
        case CLI.sacct(id) do
          {:ok, [%{} = row | _]} ->
            {next, transitioned?} = Job.update(job, row)
            {:ok, next, transitioned?}

          {:ok, []} ->
            {:ok, job, false}

          err ->
            err
        end

      err ->
        err
    end
  end

  defp emit(dispatch, %Job{state: state} = job, prev) do
    topic =
      if Job.terminal?(state),
        do: "slurm.job.#{state}",
        else: "slurm.job.transition"

    dispatch.(topic, %{job: job, previous_state: prev})
  catch
    kind, reason ->
      Logger.warning(
        "SlurmJobSensor dispatch failed: #{inspect(kind)} #{inspect(reason)}"
      )
  end

  # Default dispatch: try to use Jido.Signal if loaded; otherwise log.
  # Most deployments will pass an explicit `:dispatch` MFA pointing at the
  # agent's bus.
  defp default_dispatch(topic, payload) do
    if Code.ensure_loaded?(Jido.Signal) do
      apply(Jido.Signal, :new!, [%{type: topic, data: payload, source: "jido_hpc"}])
    else
      Logger.info("SlurmJobSensor[no-bus] #{topic}: #{inspect(payload)}")
      :ok
    end
  end

  # ---- Scheduling -------------------------------------------------------

  defp schedule(%{interval: interval, timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    jitter = trunc(interval * @default_jitter_pct / 100)
    next = interval + :rand.uniform(2 * jitter + 1) - jitter - 1
    %{state | timer: Process.send_after(self(), :poll, next)}
  end
end
