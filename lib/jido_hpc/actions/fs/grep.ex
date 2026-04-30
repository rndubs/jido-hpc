defmodule JidoHpc.Actions.FS.Grep do
  @moduledoc """
  Search for a pattern across files under an allowlisted root.

  Implemented in pure Elixir (no shell-out): traverses the directory tree
  with `Path.wildcard/1` filters and matches each file's content against
  a regex compiled from the user's `pattern`.

  Returns `{:ok, %{matches: [...], truncated?, files_scanned}}`. Each
  match is `%{path, line, text}`.
  """

  use Jido.Action,
    name: "fs_grep",
    description:
      "Search for a regex pattern under a root directory. The root must lie under the " <>
        "path_allowlist. Returns up to max_matches lines with file/line context.",
    schema: [
      pattern: [type: :string, required: true, doc: "Regex pattern (Elixir/PCRE-ish)."],
      path: [type: :string, required: true, doc: "Root to search under."],
      glob: [
        type: :string,
        default: "**/*",
        doc: "Path.wildcard glob applied under path. Default '**/*'."
      ],
      max_matches: [type: :pos_integer, default: 200],
      max_file_bytes: [
        type: :pos_integer,
        default: 1_048_576,
        doc: "Skip files larger than this (default 1 MiB)."
      ],
      case_insensitive: [type: :boolean, default: false]
    ]

  alias JidoHpc.Safety.PathGuard

  @impl true
  def run(params, ctx) do
    %{pattern: pattern, path: path, glob: glob} = params

    with {:ok, root} <- PathGuard.validate(path, ctx),
         {:ok, regex} <- compile(pattern, params.case_insensitive) do
      files =
        root
        |> Path.join(glob)
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)

      {matches, scanned, truncated?} =
        scan(files, regex, params.max_matches, params.max_file_bytes)

      {:ok,
       %{
         matches: matches,
         files_scanned: scanned,
         truncated?: truncated?,
         root: root
       }}
    end
  end

  defp compile(pattern, false), do: Regex.compile(pattern)
  defp compile(pattern, true), do: Regex.compile(pattern, "i")

  defp scan(files, regex, max_matches, max_file_bytes) do
    Enum.reduce_while(files, {[], 0, false}, fn file, {acc, scanned, _} ->
      cond do
        length(acc) >= max_matches ->
          {:halt, {Enum.reverse(acc), scanned, true}}

        skip_file?(file, max_file_bytes) ->
          {:cont, {acc, scanned + 1, false}}

        true ->
          new_acc = match_file(file, regex, acc, max_matches)
          truncated? = length(new_acc) >= max_matches

          if truncated? do
            {:halt, {Enum.reverse(new_acc), scanned + 1, true}}
          else
            {:cont, {new_acc, scanned + 1, false}}
          end
      end
    end)
    |> case do
      {acc, scanned, true} -> {acc, scanned, true}
      {acc, scanned, false} -> {Enum.reverse(acc), scanned, false}
    end
  end

  defp skip_file?(file, max_bytes) do
    case File.stat(file) do
      {:ok, %File.Stat{size: size}} -> size > max_bytes
      _ -> true
    end
  end

  defp match_file(file, regex, acc, max_matches) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split(~r/\r?\n/)
        |> Enum.with_index(1)
        |> Enum.reduce_while(acc, fn {line, lineno}, inner ->
          cond do
            length(inner) >= max_matches ->
              {:halt, inner}

            Regex.match?(regex, line) ->
              {:cont, [%{path: file, line: lineno, text: line} | inner]}

            true ->
              {:cont, inner}
          end
        end)

      _ ->
        acc
    end
  end
end
