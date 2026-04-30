defmodule JidoHpc.Actions.Bash.Run do
  @moduledoc """
  Execute an allowlisted command via `System.cmd/3`.

  This action is the only sanctioned subprocess entry point for the agent.
  It enforces three guardrails:

    1. `JidoHpc.Safety.CmdGuard` — binary must be on the allowlist; args
       must be a list of strings; no shell metacharacters.
    2. `JidoHpc.Safety.PathGuard` — if `cd:` is supplied, it must resolve
       under the path allowlist.
    3. `JidoHpc.Safety.RateLimiter` — caps concurrent subprocesses on the
       login node.

  Returns `{:ok, %{stdout, exit_status, cmd, args, cwd}}`. stderr is folded
  into stdout (`:stderr_to_stdout` on `System.cmd/3`) so the LLM sees a
  single combined output stream — matching how shell pipelines behave.
  """

  use Jido.Action,
    name: "bash_run",
    description:
      "Run an allowlisted binary with an explicit argument list. Never uses a shell. " <>
        "Use this for any external command on the login node.",
    schema: [
      cmd: [
        type: :string,
        required: true,
        doc: "Binary to execute. Must be on the configured cmd_allowlist."
      ],
      args: [
        type: {:list, :string},
        default: [],
        doc: "Arguments. Each must be a string. No shell interpolation."
      ],
      cd: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Working directory. Must lie under the path_allowlist."
      ],
      timeout_ms: [
        type: :pos_integer,
        default: 30_000,
        doc: "Soft timeout. Currently informational; enforced by callers."
      ]
    ]

  alias JidoHpc.Safety.{CmdGuard, PathGuard, RateLimiter}

  @impl true
  def run(params, ctx) do
    with {:ok, {cmd, args}} <- CmdGuard.validate(params.cmd, params.args, ctx),
         {:ok, cwd} <- resolve_cwd(params.cd, ctx),
         {:ok, {output, status}} <- execute(cmd, args, cwd) do
      {:ok,
       %{
         stdout: output,
         exit_status: status,
         cmd: cmd,
         args: args,
         cwd: cwd
       }}
    end
  end

  defp resolve_cwd(nil, _ctx), do: {:ok, nil}
  defp resolve_cwd(path, ctx), do: PathGuard.validate(path, ctx)

  defp execute(cmd, args, cwd) do
    opts =
      [stderr_to_stdout: true]
      |> maybe_add(:cd, cwd)

    case RateLimiter.run(fn -> System.cmd(cmd, args, opts) end) do
      {:error, :rate_limited} = err -> err
      {output, status} -> {:ok, {output, status}}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
