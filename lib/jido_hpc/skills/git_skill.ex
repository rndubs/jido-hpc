defmodule JidoHpc.Skills.GitSkill do
  @moduledoc """
  Read-only git actions for the agent: status, diff, log.

  Writes (commit, push, branch, etc.) are intentionally excluded from
  Phase 1 — those land later behind explicit human-approval flows.
  """

  use Jido.Plugin,
    name: "git_skill",
    state_key: :git,
    description: "Read-only git operations: status, diff, log. Repo path must be allowlisted.",
    actions: [
      JidoHpc.Actions.Git.Status,
      JidoHpc.Actions.Git.Diff,
      JidoHpc.Actions.Git.Log
    ],
    category: "git",
    tags: ["git", "vcs", "read-only"]
end
