defmodule JidoHpc.Actions.Slurm.Status do
  @moduledoc """
  Query running/pending jobs via `squeue --json`.

  Without filters, returns every job visible to the current user. Filters
  (`user`, `partition`, `job`) are passed through to `squeue`. The result
  is a list of normalized maps; the LLM never sees raw `squeue` output.
  """

  use Jido.Action,
    name: "slurm_status",
    description: "List Slurm jobs (squeue). Filter by user, partition, or job id.",
    schema: [
      user: [type: {:or, [:string, nil]}, default: nil],
      partition: [type: {:or, [:string, nil]}, default: nil],
      job: [type: {:or, [:string, nil]}, default: nil, doc: "Single job id."]
    ]

  alias JidoHpc.Slurm.{CLI, Job}

  @impl true
  def run(params, _ctx) do
    opts =
      []
      |> add_opt(:user, params.user)
      |> add_opt(:partition, params.partition)
      |> add_opt(:job, params.job)

    case CLI.squeue(opts) do
      {:ok, rows} ->
        records =
          Enum.map(rows, fn row ->
            row
            |> Map.put(:state_atom, Job.parse_state(row[:state]))
          end)

        {:ok, %{jobs: records, count: length(records)}}

      {:error, _} = err ->
        err
    end
  end

  defp add_opt(acc, _k, nil), do: acc
  defp add_opt(acc, k, v), do: Keyword.put(acc, k, v)
end
