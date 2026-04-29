import Config

config :jido_hpc,
  # Allowlist of root paths the agent may read/write.
  # Tighten via runtime.exs for production.
  path_allowlist: [
    System.get_env("HOME") || "/tmp"
  ],
  # Binary allowlist enforced by JidoHpc.Safety.CmdGuard (Phase 1).
  cmd_allowlist: ~w(
    ls cat grep rg find git
    sbatch squeue sacct scancel sinfo scontrol
    module
  ),
  # Default agent autonomy. :confirm_on_submit | :autonomous
  autonomy: :confirm_on_submit

config :jido_ai,
  default_model: {:anthropic, "claude-sonnet-4-6"}

import_config "#{config_env()}.exs"
