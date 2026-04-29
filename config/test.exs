import Config

# Tests must not hit a real LLM or a real Slurm cluster.
config :jido_hpc,
  path_allowlist: [System.tmp_dir!()],
  autonomy: :confirm_on_submit
