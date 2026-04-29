defmodule JidoHpc.Actions.Slurm.Sinfo do
  @moduledoc """
  Inspect partition / node availability via `sinfo --json`.

  Returns a list of partition records the LLM can use to pick a sensible
  partition (`-p`) before submitting.
  """

  use Jido.Action,
    name: "slurm_sinfo",
    description: "Show Slurm partition / node state (sinfo).",
    schema: []

  alias JidoHpc.Slurm.CLI

  @impl true
  def run(_params, _ctx) do
    case CLI.sinfo() do
      {:ok, rows} -> {:ok, %{partitions: rows, count: length(rows)}}
      {:error, _} = err -> err
    end
  end
end
