defmodule JidoHpc.Actions.Git.Status do
  @moduledoc """
  Run `git status --porcelain=v1 -b` inside an allowlisted repo.

  Output stays in porcelain form so the LLM can parse it deterministically.
  """

  use Jido.Action,
    name: "git_status",
    description:
      "Show git status (porcelain v1, with branch header) for a repo under the path_allowlist.",
    schema: [
      cwd: [type: :string, required: true, doc: "Repo root (or any subdir of it)."]
    ]

  alias JidoHpc.Safety.{CmdGuard, PathGuard, RateLimiter}

  @impl true
  def run(%{cwd: cwd}, ctx) do
    with {:ok, abs} <- PathGuard.validate(cwd, ctx),
         {:ok, {cmd, args}} <-
           CmdGuard.validate("git", ["status", "--porcelain=v1", "-b"], ctx),
         {:ok, {output, status}} <-
           run_cmd(cmd, args, abs) do
      {:ok, %{stdout: output, exit_status: status, cwd: abs}}
    end
  end

  defp run_cmd(cmd, args, cwd) do
    case RateLimiter.run(fn ->
           System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true)
         end) do
      {:error, :rate_limited} = err -> err
      {output, status} -> {:ok, {output, status}}
    end
  end
end
