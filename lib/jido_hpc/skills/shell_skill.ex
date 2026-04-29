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

  All file actions share the `:path_allowlist` from `:jido_hpc` config;
  all command actions share the `:cmd_allowlist`.
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
end
