defmodule JidoHpc.Actions.Git.Log do
  @moduledoc """
  Run `git log` with a fixed pretty-format inside an allowlisted repo.

  Format is intentionally machine-readable:

      <hash>\\x1f<author>\\x1f<author-email>\\x1f<iso-date>\\x1f<subject>

  (`\\x1f` = ASCII US, "unit separator" — never appears in commit text.)
  """

  use Jido.Action,
    name: "git_log",
    description:
      "Show git log for a repo under the path_allowlist. Returns up to `limit` commits in a " <>
        "machine-readable format (US-separated fields).",
    schema: [
      cwd: [type: :string, required: true],
      limit: [type: :pos_integer, default: 20],
      rev: [type: {:or, [:string, nil]}, default: nil],
      paths: [type: {:list, :string}, default: []]
    ]

  alias JidoHpc.Safety.{CmdGuard, PathGuard, RateLimiter}

  @format "%H\x1f%an\x1f%ae\x1f%aI\x1f%s"

  @impl true
  def run(%{cwd: cwd, limit: limit, rev: rev, paths: paths}, _context) do
    with {:ok, abs} <- PathGuard.validate(cwd),
         {:ok, args} <- build_args(limit, rev, paths),
         {:ok, {cmd, args}} <- CmdGuard.validate("git", args),
         {:ok, {output, status}} <- run_cmd(cmd, args, abs) do
      {:ok,
       %{
         stdout: output,
         exit_status: status,
         cwd: abs,
         entries: parse(output)
       }}
    end
  end

  defp build_args(limit, rev, paths) do
    cond do
      is_binary(rev) and String.starts_with?(rev, "-") ->
        {:error, {:invalid_rev, :flag_like}}

      Enum.any?(paths, &(not is_binary(&1))) ->
        {:error, {:invalid_paths, :non_string}}

      Enum.any?(paths, &String.starts_with?(&1, "-")) ->
        {:error, {:invalid_paths, :flag_like}}

      true ->
        base = [
          "log",
          "--pretty=format:#{@format}",
          "-n",
          Integer.to_string(limit)
        ]

        base = if rev, do: base ++ [rev], else: base

        # Always emit `--` so paths (and any future positional args)
        # cannot be parsed as flags.
        {:ok, base ++ ["--" | paths]}
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

  defp parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\x1f", parts: 5) do
        [hash, author, email, date, subject] ->
          [%{hash: hash, author: author, email: email, date: date, subject: subject}]

        _ ->
          []
      end
    end)
  end
end
