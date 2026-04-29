defmodule JidoHpc.Skills.SlurmSkill do
  @moduledoc """
  Bundles every Slurm action into a single Jido plugin so an agent
  picks them up with one line of `use`.

  Includes:

    * `JidoHpc.Actions.Slurm.Submit`
    * `JidoHpc.Actions.Slurm.Cancel`
    * `JidoHpc.Actions.Slurm.Status`
    * `JidoHpc.Actions.Slurm.Sacct`
    * `JidoHpc.Actions.Slurm.Sinfo`
    * `JidoHpc.Actions.Slurm.TemplateScript`
    * `JidoHpc.Actions.Slurm.WaitForJob`

  ## Supervised processes

  `child_spec/1` returns a spec for `JidoHpc.Sensors.SlurmJobSensor`. When
  the agent boots the skill plugin stack, the sensor is started under the
  agent's supervisor, so submitted jobs can be tracked asynchronously
  without blocking the reasoning loop.

  ## Signal routes

  Terminal Slurm transitions are routed back into the agent so it can
  react (e.g. summarize logs on completion, retry on preemption):

      slurm.job.completed → JidoHpc.Actions.Slurm.Sacct
      slurm.job.failed    → JidoHpc.Actions.Slurm.Sacct
      slurm.job.preempted → JidoHpc.Actions.Slurm.Status

  Non-terminal transitions (`slurm.job.transition`) are emitted by the
  sensor but intentionally not routed — they're informational and the
  agent can subscribe to them ad hoc.
  """

  use Jido.Plugin,
    name: "slurm_skill",
    state_key: :slurm,
    description:
      "Submit, cancel, and inspect Slurm jobs from a typed JobSpec. " <>
        "Emits signals when tracked jobs change state.",
    actions: [
      JidoHpc.Actions.Slurm.Submit,
      JidoHpc.Actions.Slurm.Cancel,
      JidoHpc.Actions.Slurm.Status,
      JidoHpc.Actions.Slurm.Sacct,
      JidoHpc.Actions.Slurm.Sinfo,
      JidoHpc.Actions.Slurm.TemplateScript,
      JidoHpc.Actions.Slurm.WaitForJob
    ],
    signal_routes: [
      {"slurm.job.completed", JidoHpc.Actions.Slurm.Sacct},
      {"slurm.job.failed", JidoHpc.Actions.Slurm.Sacct},
      {"slurm.job.preempted", JidoHpc.Actions.Slurm.Status}
    ],
    category: "slurm",
    tags: ["slurm", "scheduler", "compute-node"]

  alias JidoHpc.Sensors.SlurmJobSensor

  @doc """
  Start the `SlurmJobSensor` under the agent's supervisor.

  Sensor options can be overridden via the `:sensor` key in the skill
  config; everything else is forwarded straight to
  `SlurmJobSensor.start_link/1`.
  """
  @impl Jido.Plugin
  def child_spec(config) do
    sensor_opts = Keyword.get(config, :sensor, [])

    Supervisor.child_spec(
      {SlurmJobSensor, sensor_opts},
      id: SlurmJobSensor
    )
  end
end
