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

  Every terminal Slurm state is routed back into the agent so it can
  react (e.g. summarize logs on completion, retry on preemption,
  enlarge memory on OOM, resubmit on node failure):

      slurm.job.completed  → JidoHpc.Actions.Slurm.Sacct
      slurm.job.failed     → JidoHpc.Actions.Slurm.Sacct
      slurm.job.timeout    → JidoHpc.Actions.Slurm.Sacct
      slurm.job.oom        → JidoHpc.Actions.Slurm.Sacct
      slurm.job.cancelled  → JidoHpc.Actions.Slurm.Sacct
      slurm.job.node_fail  → JidoHpc.Actions.Slurm.Sacct
      slurm.job.preempted  → JidoHpc.Actions.Slurm.Status

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
      {"slurm.job.timeout", JidoHpc.Actions.Slurm.Sacct},
      {"slurm.job.oom", JidoHpc.Actions.Slurm.Sacct},
      {"slurm.job.cancelled", JidoHpc.Actions.Slurm.Sacct},
      {"slurm.job.node_fail", JidoHpc.Actions.Slurm.Sacct},
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

  Jido passes `config` as a map at runtime (`spec.config || %{}` in
  `Jido.AgentServer.start_plugin_spec_children/3`); we also accept a
  keyword list so test helpers and `child_spec([])` calls still work.
  """
  @impl Jido.Plugin
  def child_spec(config) do
    sensor_opts = fetch_sensor_opts(config)

    Supervisor.child_spec(
      {SlurmJobSensor, sensor_opts},
      id: SlurmJobSensor
    )
  end

  @doc """
  Snapshot the `path_allowlist` (used by `Slurm.TemplateScript` to validate
  absolute output/error paths) and the sensor name into `agent.state.slurm`
  so actions can read them from `ctx[:state][:slurm]`.

  Same fallback rules as `ShellSkill.mount/2`: explicit config wins, then
  `Application.get_env(:jido_hpc, :path_allowlist)`. The `:sensor_name`
  key lets a deployment override the registered sensor name (defaults to
  `JidoHpc.Sensors.SlurmJobSensor`); `Slurm.Submit` reads it back from ctx
  to register newly submitted jobs with the right tracker.
  """
  @impl Jido.Plugin
  def mount(_agent, config) do
    {:ok,
     %{
       path_allowlist: fetch_path_allowlist(config),
       sensor_name: fetch_sensor_name(config)
     }}
  end

  @doc "Zoi schema describing the skill's mount config."
  def schema do
    Zoi.object(%{
      path_allowlist:
        Zoi.list(Zoi.string(description: "Allowlisted root for log paths"),
          description: "Roots Slurm.TemplateScript validates absolute output/error against"
        )
        |> Zoi.default([]),
      sensor:
        Zoi.any(description: "Opts forwarded to SlurmJobSensor.start_link/1")
        |> Zoi.optional(),
      sensor_name:
        Zoi.any(description: "Registered name for the sensor (defaults to module name)")
        |> Zoi.optional()
    })
  end

  defp fetch_sensor_opts(config) when is_map(config), do: Map.get(config, :sensor, [])
  defp fetch_sensor_opts(config) when is_list(config), do: Keyword.get(config, :sensor, [])

  defp fetch_sensor_name(config) when is_map(config),
    do: Map.get(config, :sensor_name, SlurmJobSensor)

  defp fetch_sensor_name(config) when is_list(config),
    do: Keyword.get(config, :sensor_name, SlurmJobSensor)

  defp fetch_path_allowlist(config) when is_map(config) do
    Map.get(config, :path_allowlist) || Application.get_env(:jido_hpc, :path_allowlist, [])
  end

  defp fetch_path_allowlist(config) when is_list(config) do
    Keyword.get(config, :path_allowlist) || Application.get_env(:jido_hpc, :path_allowlist, [])
  end
end
