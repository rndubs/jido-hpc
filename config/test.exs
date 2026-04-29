import Config

# Tests must not hit a real LLM or a real Slurm cluster.
config :jido_hpc,
  path_allowlist: [System.tmp_dir!()],
  autonomy: :confirm_on_submit,
  # Most tests should not touch a real audit log. Tests that exercise
  # the audit pipeline override this with a tmp path in their setup.
  audit_log_path: :disabled
