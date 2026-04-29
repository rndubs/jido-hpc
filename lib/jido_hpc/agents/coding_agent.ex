defmodule JidoHpc.Agents.CodingAgent do
  @moduledoc """
  The top-level coding agent for `jido_hpc`.

  Built on `Jido.AI.Agent`, which provides a ReAct-style loop driving an
  LLM (Anthropic by default — see `config :jido_ai, :default_model`).
  Three skills wire in every action the agent can take:

    * `JidoHpc.Skills.SlurmSkill` — submit / cancel / inspect Slurm jobs,
      plus an async `SlurmJobSensor` that signals state changes
    * `JidoHpc.Skills.ShellSkill`  — login-node bash + filesystem ops,
      gated by `Safety.PathGuard` and `Safety.CmdGuard`
    * `JidoHpc.Skills.GitSkill`    — read-only git (status / diff / log)

  Tools are always discovered via skills, never hand-listed here, so the
  set the LLM sees stays in sync with what the skill modules export.

  ## System prompt

  The default prompt nudges the model toward the Phase 2 contract:

    * use the typed `JobSpec` actions; never hand-write sbatch
    * stay inside the path allowlist
    * favour read-only inspection before destructive ops

  Override via `:system_prompt` in the agent's config if the deployment
  needs different guardrails.
  """

  use Jido.AI.Agent,
    name: "jido_hpc_coding_agent",
    description:
      "HPC coding agent: drives Slurm and edits files on the login node via typed Jido actions.",
    tools: [
      JidoHpc.Actions.Slurm.Submit,
      JidoHpc.Actions.Slurm.Cancel,
      JidoHpc.Actions.Slurm.Status,
      JidoHpc.Actions.Slurm.Sacct,
      JidoHpc.Actions.Slurm.Sinfo,
      JidoHpc.Actions.Slurm.TemplateScript,
      JidoHpc.Actions.Slurm.WaitForJob,
      JidoHpc.Actions.Bash.Run,
      JidoHpc.Actions.FS.Read,
      JidoHpc.Actions.FS.Write,
      JidoHpc.Actions.FS.Edit,
      JidoHpc.Actions.FS.Grep,
      JidoHpc.Actions.FS.Ls,
      JidoHpc.Actions.FS.Glob,
      JidoHpc.Actions.Git.Status,
      JidoHpc.Actions.Git.Diff,
      JidoHpc.Actions.Git.Log
    ],
    system_prompt: """
    You are the jido_hpc coding agent, running on an HPC login node.

    Operating rules:
      * To run compute work, fill a JobSpec via slurm_template_script or
        slurm_submit. Never write raw sbatch text.
      * File reads/writes go through fs_read / fs_write / fs_edit /
        fs_grep / fs_ls / fs_glob and are confined to the configured
        path allowlist; do not try to escape it with `..`.
      * Bash commands go through bash_run with arg lists, not shell
        strings. The binary allowlist is enforced server-side.
      * Prefer read-only inspection (slurm_status, slurm_sacct, fs_read,
        fs_grep, git_status, git_diff, git_log) before any destructive
        action.
      * When autonomy is :confirm_on_submit, slurm_submit returns a
        rendered script for human review; surface it to the user
        verbatim and wait for confirmation before re-submitting with
        confirm: true.
    """
end
