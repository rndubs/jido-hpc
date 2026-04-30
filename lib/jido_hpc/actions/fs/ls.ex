defmodule JidoHpc.Actions.FS.Ls do
  @moduledoc """
  List directory contents after path-allowlist validation.

  Returns `{:ok, %{path, entries}}` where each entry is
  `%{name, type, size, mtime}`. Hidden entries (leading dot) are
  excluded by default.
  """

  use Jido.Action,
    name: "fs_ls",
    description: "List entries in a directory. The path must lie under the path_allowlist.",
    schema: [
      path: [type: :string, required: true],
      include_hidden?: [type: :boolean, default: false]
    ]

  alias JidoHpc.Safety.PathGuard

  @impl true
  def run(%{path: path, include_hidden?: include_hidden?}, ctx) do
    with {:ok, abs} <- PathGuard.validate(path, ctx),
         {:ok, names} <- File.ls(abs) do
      entries =
        names
        |> maybe_filter_hidden(include_hidden?)
        |> Enum.sort()
        |> Enum.map(&entry(abs, &1))

      {:ok, %{path: abs, entries: entries}}
    end
  end

  defp maybe_filter_hidden(names, true), do: names

  defp maybe_filter_hidden(names, false),
    do: Enum.reject(names, &String.starts_with?(&1, "."))

  defp entry(parent, name) do
    full = Path.join(parent, name)

    case File.stat(full) do
      {:ok, %File.Stat{type: type, size: size, mtime: mtime}} ->
        %{name: name, type: type, size: size, mtime: mtime}

      {:error, _} ->
        %{name: name, type: :unknown, size: nil, mtime: nil}
    end
  end
end
