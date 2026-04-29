defmodule JidoHpc.Actions.Git.Diff do
  @moduledoc """
  Run `git diff` inside an allowlisted repo.

  Without `:rev`, shows the working-tree diff against HEAD. With a `rev`
  (e.g. `"main"`, `"HEAD~3"`, `"abcdef..HEAD"`) it diffs against that ref.
  Read-only — never writes to the index.
  """

  use Jido.Action,
    name: "git_diff",
    description: "Show git diff for a repo under the path_allowlist. Read-only.",
    schema: [
      cwd: [type: :string, required: true],
      rev: [type: {:or, [:string, nil]}, default: nil],
      staged?: [type: :boolean, default: false],
      paths: [type: {:list, :string}, default: []],
      max_bytes: [type: :pos_integer, default: 256 * 1024]
    ]

  alias JidoHpc.Safety.{CmdGuard, PathGuard, RateLimiter}

  @impl true
  def run(params, _context) do
    %{cwd: cwd, rev: rev, staged?: staged?, paths: paths, max_bytes: max_bytes} = params

    with {:ok, abs} <- PathGuard.validate(cwd),
         {:ok, args} <- build_args(rev, staged?, paths),
         {:ok, {cmd, args}} <- CmdGuard.validate("git", args),
         {:ok, {output, status}} <- run_cmd(cmd, args, abs) do
      {truncated, body} = truncate(output, max_bytes)

      {:ok,
       %{
         stdout: body,
         exit_status: status,
         cwd: abs,
         truncated?: truncated,
         byte_size: byte_size(body)
       }}
    end
  end

  defp build_args(rev, staged?, paths) do
    base =
      ["diff"]
      |> maybe_add_flag("--cached", staged?)
      |> maybe_add(rev)

    cond do
      Enum.any?(paths, &(not is_binary(&1))) ->
        {:error, {:invalid_paths, :non_string}}

      paths == [] ->
        {:ok, base}

      true ->
        {:ok, base ++ ["--" | paths]}
    end
  end

  defp maybe_add_flag(args, _flag, false), do: args
  defp maybe_add_flag(args, flag, true), do: args ++ [flag]

  defp maybe_add(args, nil), do: args
  defp maybe_add(args, rev) when is_binary(rev), do: args ++ [rev]

  defp run_cmd(cmd, args, cwd) do
    case RateLimiter.run(fn ->
           System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true)
         end) do
      {:error, :rate_limited} = err -> err
      {output, status} -> {:ok, {output, status}}
    end
  end

  defp truncate(output, max) when byte_size(output) > max,
    do: {true, binary_part(output, 0, max)}

  defp truncate(output, _max), do: {false, output}
end
