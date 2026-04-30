defmodule JidoHpc.Skills.GitSkill do
  @moduledoc """
  Read-only git actions for the agent: status, diff, log.

  Writes (commit, push, branch, etc.) are intentionally excluded from
  Phase 1 — those land later behind explicit human-approval flows.

  ## Mount config

  Snapshots `path_allowlist` into `agent.state.git` for ctx-based lookups
  in actions. Same pattern as `ShellSkill` and `SlurmSkill`.

    * `:path_allowlist` — list of root directories. Defaults to
      `Application.get_env(:jido_hpc, :path_allowlist, [])`.
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

  @impl Jido.Plugin
  def mount(_agent, config) do
    {:ok, %{path_allowlist: fetch_path_allowlist(config)}}
  end

  @doc "Zoi schema describing the skill's mount config."
  def schema do
    Zoi.object(%{
      path_allowlist:
        Zoi.list(Zoi.string(description: "Allowlisted repo root"),
          description: "Repo roots git_* actions may inspect"
        )
        |> Zoi.default([])
    })
  end

  defp fetch_path_allowlist(config) when is_map(config) do
    Map.get(config, :path_allowlist) || Application.get_env(:jido_hpc, :path_allowlist, [])
  end

  defp fetch_path_allowlist(config) when is_list(config) do
    Keyword.get(config, :path_allowlist) || Application.get_env(:jido_hpc, :path_allowlist, [])
  end
end
