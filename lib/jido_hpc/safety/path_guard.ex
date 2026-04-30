defmodule JidoHpc.Safety.PathGuard do
  @moduledoc """
  Validates filesystem paths against an allowlist of root directories.

  Rejects:
    * non-binary input
    * any literal `..` segment in the raw input (defense-in-depth, even
      though `Path.expand/1` would resolve them)
    * any path whose absolute, expanded form does not lie under a
      configured allowlist root
    * empty / whitespace-only paths

  The allowlist comes from `Application.get_env(:jido_hpc, :path_allowlist)`
  by default. Tests may pass `:roots` explicitly to bypass app config.

  This module performs **lexical** validation only. It does not stat the
  path nor resolve symlinks; callers that care about symlink escape must
  layer their own check on top.
  """

  @type validation_opts :: [roots: [String.t()]] | map()

  @doc """
  Validate `path` against the allowlist. Returns `{:ok, abs_path}` (where
  `abs_path` is the expanded, absolute form) or `{:error, reason}`.

  The second argument can be either a keyword list of opts (`roots:` for
  test overrides) or an action `ctx` map. When given a ctx, the guard
  reads roots from `ctx[:state][:shell][:path_allowlist]` (preferred,
  populated by `ShellSkill.mount/2`) or `ctx[:state][:slurm][:path_allowlist]`
  / `ctx[:state][:git][:path_allowlist]`, falling back to
  `Application.get_env(:jido_hpc, :path_allowlist)` when no plugin state
  is present (e.g. for non-agent callers).
  """
  @spec validate(term(), validation_opts()) :: {:ok, String.t()} | {:error, term()}
  def validate(path, opts \\ [])

  def validate(path, _opts) when not is_binary(path) do
    {:error, {:invalid_path, :not_a_string}}
  end

  def validate(path, opts) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, {:invalid_path, :empty}}

      contains_dotdot_segment?(path) ->
        {:error, {:invalid_path, :dotdot_segment}}

      String.contains?(path, <<0>>) ->
        {:error, {:invalid_path, :null_byte}}

      true ->
        roots = roots(opts)
        abs = Path.expand(path)

        if under_any_root?(abs, roots) do
          {:ok, abs}
        else
          {:error, {:outside_allowlist, abs}}
        end
    end
  end

  @doc """
  Bang variant: returns the absolute path or raises `ArgumentError`.
  """
  @spec validate!(term(), validation_opts()) :: String.t()
  def validate!(path, opts \\ []) do
    case validate(path, opts) do
      {:ok, abs} -> abs
      {:error, reason} -> raise ArgumentError, "path rejected: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the configured allowlist roots, expanded to absolute paths.

  Accepts either a keyword opts list (`roots:` override) or an action ctx
  map (reads from plugin state). Empty / missing config falls back to
  `Application.get_env(:jido_hpc, :path_allowlist)`.
  """
  @spec roots(validation_opts()) :: [String.t()]
  def roots(opts \\ [])

  def roots(opts) when is_list(opts) do
    raw =
      Keyword.get(opts, :roots) ||
        Application.get_env(:jido_hpc, :path_allowlist, [])

    expand_roots(raw)
  end

  def roots(ctx) when is_map(ctx) do
    raw = roots_from_ctx(ctx) || Application.get_env(:jido_hpc, :path_allowlist, [])
    expand_roots(raw)
  end

  defp roots_from_ctx(ctx) do
    state = Map.get(ctx, :state) || %{}

    Enum.find_value([:shell, :slurm, :git], fn key ->
      case Map.get(state, key) do
        %{path_allowlist: roots} when is_list(roots) and roots != [] -> roots
        _ -> nil
      end
    end)
  end

  defp expand_roots(raw) do
    raw
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&Path.expand/1)
  end

  defp contains_dotdot_segment?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  defp under_any_root?(_abs, []), do: false

  defp under_any_root?(abs, roots) do
    Enum.any?(roots, fn root -> path_under?(abs, root) end)
  end

  # `abs == root` or `abs` begins with `root <> "/"`. We use string prefix
  # rather than `Path.relative_to/2` because the latter silently returns
  # the original path on no-match.
  defp path_under?(abs, root) do
    abs == root or String.starts_with?(abs, root <> "/")
  end
end
