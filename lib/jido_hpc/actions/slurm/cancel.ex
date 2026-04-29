defmodule JidoHpc.Actions.Slurm.Cancel do
  @moduledoc """
  Cancel a Slurm job by id (`scancel <id>`).

  Accepts plain numeric IDs or array forms (`12345_7`). Anything else is
  rejected before reaching the CLI.
  """

  use Jido.Action,
    name: "slurm_cancel",
    description: "Cancel a Slurm job by id.",
    schema: [
      job_id: [type: :string, required: true, doc: "Slurm job id, e.g. \"12345\" or \"12345_3\"."]
    ]

  alias JidoHpc.Slurm.CLI

  @id_re ~r/^\d+(_\d+)?$/

  @impl true
  def run(%{job_id: id}, _ctx) do
    if Regex.match?(@id_re, id) do
      case CLI.scancel(id) do
        :ok -> {:ok, %{job_id: id, cancelled: true}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:invalid_job_id, id}}
    end
  end
end
