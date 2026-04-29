defmodule JidoHpc.Slurm.CLI do
  @moduledoc """
  Thin behaviour wrapper over the Slurm command-line tools (`sbatch`,
  `squeue`, `sacct`, `scancel`, `sinfo`, `scontrol`).

  All actions in `JidoHpc.Actions.Slurm.*` and the `SlurmJobSensor` go
  through this module — they never call `System.cmd/3` directly. That
  centralizes:

    * the binary allowlist check (via `Safety.CmdGuard`)
    * `--json` parsing with `--parsable2 --format=…` fallback
    * the rate-limiter
    * test-time stubbing

  ## Test stubbing

  Tests configure an alternate implementation via app env:

      Application.put_env(:jido_hpc, :slurm_cli, MyStub)

  `MyStub` only needs to implement the callbacks it cares about. The
  default implementation is `JidoHpc.Slurm.CLI.Real`.

  ## Return shape

  Every function returns `{:ok, term}` or `{:error, term}`. Records are
  plain maps with atom keys (`:job_id`, `:state`, `:reason`, `:elapsed`,
  `:exit_code`, `:max_rss`, `:partition`, ...). Callers should never need
  to scrape strings.
  """

  alias JidoHpc.Slurm.JobSpec

  @type job_id :: String.t()
  @type record :: %{optional(atom()) => term()}

  @callback sbatch(script_path :: String.t(), spec :: JobSpec.t() | nil) ::
              {:ok, %{job_id: job_id(), stdout: String.t()}} | {:error, term()}
  @callback squeue(opts :: keyword()) :: {:ok, [record()]} | {:error, term()}
  @callback sacct(job_id(), opts :: keyword()) :: {:ok, [record()]} | {:error, term()}
  @callback scancel(job_id(), opts :: keyword()) :: :ok | {:error, term()}
  @callback sinfo(opts :: keyword()) :: {:ok, [record()]} | {:error, term()}
  @callback scontrol_show_job(job_id(), opts :: keyword()) ::
              {:ok, record()} | {:error, term()}

  @optional_callbacks scontrol_show_job: 2

  # ---- Public dispatcher ------------------------------------------------

  def sbatch(script_path, spec \\ nil), do: impl().sbatch(script_path, spec)
  def squeue(opts \\ []), do: impl().squeue(opts)
  def sacct(job_id, opts \\ []), do: impl().sacct(job_id, opts)
  def scancel(job_id, opts \\ []), do: impl().scancel(job_id, opts)
  def sinfo(opts \\ []), do: impl().sinfo(opts)

  def scontrol_show_job(job_id, opts \\ []) do
    mod = impl()
    _ = Code.ensure_loaded(mod)

    if function_exported?(mod, :scontrol_show_job, 2) do
      mod.scontrol_show_job(job_id, opts)
    else
      {:error, :not_implemented}
    end
  end

  @doc "Returns the configured implementation module."
  @spec impl() :: module()
  def impl do
    Application.get_env(:jido_hpc, :slurm_cli, JidoHpc.Slurm.CLI.Real)
  end
end
