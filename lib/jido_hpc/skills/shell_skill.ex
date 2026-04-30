defmodule JidoHpc.Skills.ShellSkill do
  @moduledoc """
  Bundles the login-node shell + filesystem actions into a single Jido
  plugin so an agent can `use` it with one line.

  Includes:

    * `JidoHpc.Actions.Bash.Run`
    * `JidoHpc.Actions.FS.Read`
    * `JidoHpc.Actions.FS.Write`
    * `JidoHpc.Actions.FS.Edit`
    * `JidoHpc.Actions.FS.Grep`
    * `JidoHpc.Actions.FS.Ls`
    * `JidoHpc.Actions.FS.Glob`

  ## Mount config

  At mount time the skill snapshots the path/cmd allowlists into
  `agent.state.shell` so actions can read them from `ctx[:state][:shell]`
  instead of reaching back to `Application.get_env`. This is the
  framework-idiomatic equivalent to the `Application` env fallback the
  guards (`PathGuard` / `CmdGuard`) keep for non-agent callers (e.g.
  `Jido.Exec.run/2` from a Mix task).

  Config keys (all optional):

    * `:path_allowlist` — list of root directories. Defaults to
      `Application.get_env(:jido_hpc, :path_allowlist, [])`.
    * `:cmd_allowlist`  — list of allowed binary basenames. Defaults to
      `Application.get_env(:jido_hpc, :cmd_allowlist, [])`.
  """

  use Jido.Plugin,
    name: "shell_skill",
    state_key: :shell,
    description:
      "Login-node primitives: run allowlisted bash commands and read/write files inside the path allowlist.",
    actions: [
      JidoHpc.Actions.Bash.Run,
      JidoHpc.Actions.FS.Read,
      JidoHpc.Actions.FS.Write,
      JidoHpc.Actions.FS.Edit,
      JidoHpc.Actions.FS.Grep,
      JidoHpc.Actions.FS.Ls,
      JidoHpc.Actions.FS.Glob
    ],
    category: "shell",
    tags: ["filesystem", "bash", "login-node"]

  @impl Jido.Plugin
  def mount(_agent, config) do
    {:ok,
     %{
       path_allowlist: fetch(config, :path_allowlist, :path_allowlist),
       cmd_allowlist: fetch(config, :cmd_allowlist, :cmd_allowlist)
     }}
  end

  @doc """
  Zoi schema describing the skill's mount config.

  Mirrors `Jido.AI.Plugins.Chat.schema/0` — purely descriptive so a future
  validator (or an LLM reading `tools_from_skills/1` metadata) knows what
  shape this plugin's config takes. Both lists default to `[]`.
  """
  def schema do
    Zoi.object(%{
      path_allowlist:
        Zoi.list(Zoi.string(description: "Allowlisted root directory"),
          description: "Directories actions may read/write under"
        )
        |> Zoi.default([]),
      cmd_allowlist:
        Zoi.list(Zoi.string(description: "Allowlisted binary basename"),
          description: "Binaries Bash.Run may exec"
        )
        |> Zoi.default([])
    })
  end

  defp fetch(config, key, app_key) when is_map(config) do
    case Map.get(config, key) do
      nil -> Application.get_env(:jido_hpc, app_key, [])
      value -> value
    end
  end

  defp fetch(config, key, app_key) when is_list(config) do
    case Keyword.get(config, key) do
      nil -> Application.get_env(:jido_hpc, app_key, [])
      value -> value
    end
  end
end
