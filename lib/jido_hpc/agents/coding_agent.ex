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

  ## Tunings vs the macro defaults

  Most options below are explicit overrides of `Jido.AI.Agent`'s defaults
  because the defaults are tuned for chat agents, not HPC tooling:

    * `model: :capable` — the macro default `:fast` under-serves a
      coding agent that has to plan multi-step Slurm submissions.
    * `tool_timeout_ms: 60_000` — `sacct` on a busy cluster, `sbatch`
      round-trips, and `WaitForJob` will exceed the 15s default.
    * `max_iterations: 20` — multi-step submit→inspect→retry workflows
      can run long.
    * `request_policy: :reject` — explicit; the REPL is single-user.
      Reject concurrent `ask/2` rather than queueing.
    * `effect_policy` — narrow allow-list mirroring the OS-layer guards
      (`PathGuard` / `CmdGuard`). The strategy effect policy further
      restricts emit prefixes to `slurm.*` and `jido_hpc.*`.
    * `tool_context: %{autonomy: :confirm_on_submit}` — default the LLM
      and tools see; `JidoHpc.REPL` overrides per-request via
      `tool_context: %{autonomy: state.autonomy}` on each `ask/3`.

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
    model: :capable,
    max_iterations: 20,
    tool_timeout_ms: 60_000,
    request_policy: :reject,
    # `tools:` and `plugins:` are both required as literal lists by the
    # `Jido.AI.Agent` macro (it walks the AST at compile time and can't
    # evaluate function calls or module attributes). The two stay in
    # sync via a regression test in `JidoHpc.SkillsTest` that asserts
    # this list equals `union(skill.actions/0)`.
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
    plugins: [
      JidoHpc.Skills.SlurmSkill,
      JidoHpc.Skills.ShellSkill,
      JidoHpc.Skills.GitSkill
    ],
    # Bound the framework-layer effects a tool may emit. Mirrors the
    # OS-layer hardening (PathGuard / CmdGuard) at the agent layer.
    # An agent cannot broaden a parent policy; specialists may narrow.
    effect_policy: %{
      mode: :allow_list,
      allow: [Jido.Agent.StateOp.SetState, Jido.Agent.Directive.Emit]
    },
    strategy_effect_policy: %{
      constraints: %{
        emit: %{allowed_signal_prefixes: ["slurm.", "jido_hpc."]}
      }
    },
    # Compile-time literal default. Per-request overrides come through
    # `ask/3`'s `tool_context:` option (REPL passes the active autonomy).
    # `Slurm.Submit` reads ctx.autonomy first, then params.autonomy,
    # then `Application.get_env(:jido_hpc, :autonomy)`.
    tool_context: %{autonomy: :confirm_on_submit},
    system_prompt: """
    You are the jido_hpc coding agent, running on an HPC login node.

    You have these actions available:

      * Slurm — slurm_template_script, slurm_submit, slurm_cancel,
        slurm_status, slurm_sacct, slurm_sinfo, slurm_wait_for_job
      * Filesystem — fs_read, fs_write, fs_edit, fs_grep, fs_ls, fs_glob
      * Bash — bash_run
      * Git (read-only) — git_status, git_diff, git_log

    Operating rules:
      * To run compute work, fill a JobSpec via slurm_template_script or
        slurm_submit. Never write raw sbatch text.
      * File reads/writes go through the fs_* actions and are confined
        to the configured path allowlist; do not try to escape it
        with `..`.
      * Bash commands go through bash_run with arg lists, not shell
        strings. The binary allowlist is enforced server-side.
      * Prefer read-only inspection (slurm_status, slurm_sacct,
        slurm_sinfo, fs_read, fs_grep, fs_ls, fs_glob, git_status,
        git_diff, git_log) before any destructive action.
      * When autonomy is :confirm_on_submit, slurm_submit returns a
        rendered script for human review; surface it to the user
        verbatim and wait for confirmation before re-submitting with
        confirm: true.
    """
end
