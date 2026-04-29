defmodule JidoHpc.Actions.FS.Glob do
  @moduledoc """
  Expand a glob pattern under a path-allowlisted root.

  Each returned path is also re-checked against the allowlist, so symlink
  trees that point outside the allowlist still cannot be enumerated to
  the LLM.
  """

  use Jido.Action,
    name: "fs_glob",
    description:
      "Expand a glob (e.g. '**/*.ex') under a directory. The root must lie under the " <>
        "path_allowlist. Each result is itself allowlist-checked.",
    schema: [
      root: [type: :string, required: true],
      pattern: [type: :string, required: true],
      max_results: [type: :pos_integer, default: 1_000]
    ]

  alias JidoHpc.Safety.PathGuard

  @impl true
  def run(%{root: root, pattern: pattern, max_results: max}, _context) do
    with {:ok, abs_root} <- PathGuard.validate(root) do
      paths =
        abs_root
        |> Path.join(pattern)
        |> Path.wildcard()
        |> Enum.filter(fn p -> match?({:ok, _}, PathGuard.validate(p)) end)
        |> Enum.take(max + 1)

      {results, truncated?} =
        case paths do
          list when length(list) > max -> {Enum.take(list, max), true}
          list -> {list, false}
        end

      {:ok, %{root: abs_root, pattern: pattern, paths: results, truncated?: truncated?}}
    end
  end
end
