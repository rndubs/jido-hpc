defmodule JidoHpc.Actions.Slurm.WaitForJob do
  @moduledoc """
  Block (with a deadline) until a job reaches a terminal state, then return
  the final `JidoHpc.Slurm.Job` record.

  Polls `squeue` first; once the job disappears from `squeue`, falls back
  to `sacct` for the final state. Default poll interval is 5s; default
  timeout is 30 minutes. The action returns `{:error, :timeout}` if the
  deadline elapses with the job still not terminal.

  > Long jobs should rely on `JidoHpc.Sensors.SlurmJobSensor` instead —
  > this action exists for short jobs and tests.
  """

  use Jido.Action,
    name: "slurm_wait_for_job",
    description:
      "Wait for a job to reach a terminal Slurm state (completed/failed/timeout/oom/cancelled).",
    schema: [
      job_id: [type: :string, required: true],
      poll_interval_ms: [type: :pos_integer, default: 5_000],
      timeout_ms: [type: :pos_integer, default: 30 * 60 * 1_000]
    ]

  alias JidoHpc.Slurm.{CLI, Job}

  @id_re ~r/^\d+(_\d+)?$/

  @impl true
  def run(params, _ctx) do
    %{job_id: id, poll_interval_ms: interval, timeout_ms: timeout} = params

    if not Regex.match?(@id_re, id) do
      {:error, {:invalid_job_id, id}}
    else
      deadline = System.monotonic_time(:millisecond) + timeout
      poll(id, interval, deadline)
    end
  end

  defp poll(id, interval, deadline) do
    case current_state(id) do
      {:ok, state, fields} ->
        terminate_or_wait(id, state, fields, interval, deadline)

      {:error, :not_found} ->
        # Job is no longer in squeue — pull from sacct for final state.
        # If sacct returns a non-terminal row (rare but possible — e.g.
        # the job was briefly absent from squeue between poll cycles),
        # treat it like any other non-terminal state and keep waiting.
        case sacct_lookup(id) do
          {:ok, %{state: atom, raw_state: rs, fields: f}} when atom != :unknown ->
            terminate_or_wait(id, rs, f, interval, deadline)

          {:ok, _} = ambiguous ->
            ambiguous

          {:error, :not_found} ->
            wait_or_timeout(id, interval, deadline)

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp terminate_or_wait(id, state, fields, interval, deadline) do
    atom = Job.parse_state(state)

    cond do
      Job.terminal?(atom) ->
        {:ok, %{job_id: id, state: atom, raw_state: state, fields: fields}}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(interval)
        poll(id, interval, deadline)
    end
  end

  defp wait_or_timeout(id, interval, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      Process.sleep(interval)
      poll(id, interval, deadline)
    end
  end

  defp current_state(id) do
    case CLI.squeue(job: id) do
      {:ok, []} -> {:error, :not_found}
      {:ok, [%{state: state} = first | _]} -> {:ok, state, first}
      {:error, _} = err -> err
    end
  end

  defp sacct_lookup(id) do
    case CLI.sacct(id) do
      {:ok, [%{state: state} = first | _]} ->
        atom = Job.parse_state(state)
        {:ok, %{job_id: id, state: atom, raw_state: state, fields: first}}

      {:ok, []} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end
end
