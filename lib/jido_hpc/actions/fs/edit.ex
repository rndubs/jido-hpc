defmodule JidoHpc.Actions.FS.Edit do
  @moduledoc """
  Claude-Code-style exact-match file edit.

  Replaces `old_string` with `new_string` in the file at `path`. The match
  must occur **exactly once** unless `replace_all: true` is set, in which
  case all occurrences are replaced.

  Forces read-before-edit semantics: `old_string` must be present, so the
  agent cannot blind-write a file it has not seen.
  """

  use Jido.Action,
    name: "fs_edit",
    description:
      "Edit a file by replacing an exact substring. Match must be unique unless replace_all " <>
        "is true. The path must lie under an allowlisted root.",
    schema: [
      path: [type: :string, required: true],
      old_string: [type: :string, required: true],
      new_string: [type: :string, required: true],
      replace_all: [type: :boolean, default: false]
    ]

  alias JidoHpc.Safety.PathGuard

  @impl true
  def run(params, ctx) do
    %{
      path: path,
      old_string: old,
      new_string: new,
      replace_all: replace_all
    } = params

    cond do
      old == "" ->
        {:error, {:invalid_edit, :empty_old_string}}

      old == new ->
        {:error, {:invalid_edit, :no_op}}

      true ->
        with {:ok, abs} <- PathGuard.validate(path, ctx),
             {:ok, content} <- File.read(abs),
             {:ok, updated, count} <- apply_edit(content, old, new, replace_all),
             :ok <- File.write(abs, updated) do
          {:ok, %{path: abs, replacements: count, byte_size: byte_size(updated)}}
        end
    end
  end

  defp apply_edit(content, old, new, true) do
    case occurrences(content, old) do
      0 -> {:error, {:not_found, old}}
      n -> {:ok, String.replace(content, old, new), n}
    end
  end

  defp apply_edit(content, old, new, false) do
    case occurrences(content, old) do
      0 -> {:error, {:not_found, old}}
      1 -> {:ok, String.replace(content, old, new), 1}
      n -> {:error, {:not_unique, n}}
    end
  end

  defp occurrences(haystack, needle) do
    haystack
    |> :binary.matches(needle)
    |> length()
  end
end
