defmodule JidoHpc.Actions.Slurm.TemplateScript do
  @moduledoc """
  Build a `JidoHpc.Slurm.JobSpec` from LLM-supplied fields and render it to
  an sbatch script. Returns both the spec and the rendered text. Does NOT
  submit — pair this with `Slurm.Submit` (or human approval) to actually run.

  This is also the action the LLM uses for "plan first" review: render the
  script for the human, then submit only after approval.
  """

  use Jido.Action,
    name: "slurm_template_script",
    description:
      "Render an sbatch script from a typed JobSpec (no submission). " <>
        "Use this to preview a job before submitting.",
    schema: [
      name: [type: :string, required: true, doc: "Job name."],
      time: [type: :string, required: true, doc: "Walltime, e.g. \"01:00:00\"."],
      workdir: [type: :string, required: true, doc: "Working directory (must be allowlisted)."],
      command: [
        type: {:list, :string},
        required: true,
        doc: "Command argv. Each element is a separate string."
      ],
      nodes: [type: :pos_integer, default: 1],
      ntasks: [type: :pos_integer, default: 1],
      cpus_per_task: [type: :pos_integer, default: 1],
      mem: [type: {:or, [:string, nil]}, default: nil, doc: "e.g. \"32G\"."],
      gpus: [type: {:or, [:non_neg_integer, nil]}, default: nil],
      partition: [type: {:or, [:string, nil]}, default: nil],
      modules: [type: {:list, :string}, default: []],
      env: [type: :map, default: %{}],
      array: [type: {:or, [:string, nil]}, default: nil],
      dependency: [type: {:or, [:string, nil]}, default: nil],
      output: [type: {:or, [:string, nil]}, default: nil],
      error: [type: {:or, [:string, nil]}, default: nil],
      account: [type: {:or, [:string, nil]}, default: nil],
      qos: [type: {:or, [:string, nil]}, default: nil]
    ]

  alias JidoHpc.Safety.PathGuard
  alias JidoHpc.Slurm.{JobSpec, Script}

  @impl true
  def run(params, _ctx) do
    # Absolute output/error paths (`/var/log/foo.out`) bypass --chdir,
    # so they have to clear the path allowlist independently. Relative
    # paths are resolved by Slurm against the validated workdir, so
    # they're already covered.
    with {:ok, abs_workdir} <- PathGuard.validate(params.workdir),
         :ok <- validate_optional_abs(params[:output]),
         :ok <- validate_optional_abs(params[:error]),
         {:ok, spec} <- JobSpec.new(spec_attrs(params, abs_workdir)),
         {:ok, script} <- Script.render(spec) do
      {:ok, %{spec: spec, script: script, workdir: abs_workdir}}
    end
  end

  defp validate_optional_abs(nil), do: :ok

  defp validate_optional_abs(path) when is_binary(path) do
    case Path.type(path) do
      :absolute ->
        case PathGuard.validate(path) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end

      _ ->
        :ok
    end
  end

  @spec_keys ~w(name time nodes ntasks cpus_per_task mem gpus partition
    modules env command array dependency output error account qos)a

  defp spec_attrs(params, abs_workdir) do
    params
    |> Map.take(@spec_keys)
    |> Map.put(:workdir, abs_workdir)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
