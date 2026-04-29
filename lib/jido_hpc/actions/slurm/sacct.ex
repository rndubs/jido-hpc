defmodule JidoHpc.Actions.Slurm.Sacct do
  @moduledoc """
  Look up accounting info for a finished (or running) job via `sacct --json`.

  Returns parsed records — the LLM never sees raw text. Each record has
  `:job_id`, `:state` (raw), `:state_atom`, `:exit_code`, `:elapsed`, etc.
  """

  use Jido.Action,
    name: "slurm_sacct",
    description: "Fetch Slurm accounting (sacct) records for a job id.",
    schema: [
      job_id: [type: :string, required: true]
    ]

  alias JidoHpc.Slurm.{CLI, Job}

  @id_re ~r/^\d+(_\d+)?$/

  @impl true
  def run(%{job_id: id}, _ctx) do
    if Regex.match?(@id_re, id) do
      case CLI.sacct(id) do
        {:ok, rows} ->
          records =
            Enum.map(rows, fn row ->
              Map.put(row, :state_atom, Job.parse_state(row[:state]))
            end)

          {:ok, %{job_id: id, records: records, count: length(records)}}

        {:error, _} = err ->
          err
      end
    else
      {:error, {:invalid_job_id, id}}
    end
  end
end
