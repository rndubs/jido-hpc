defmodule JidoHpc.Actions.FS.Write do
  @moduledoc """
  Write content to a file after path-allowlist validation.

  Defaults to refusing to overwrite an existing file. Pass
  `overwrite: true` to clobber. The parent directory must already exist
  unless `mkdir_p?: true` is set.
  """

  use Jido.Action,
    name: "fs_write",
    description:
      "Write a UTF-8 file. By default refuses to overwrite. The path must lie under an " <>
        "allowlisted root.",
    schema: [
      path: [type: :string, required: true],
      content: [type: :string, required: true],
      overwrite: [type: :boolean, default: false],
      mkdir_p?: [
        type: :boolean,
        default: false,
        doc: "If true, create the parent directory if it doesn't exist."
      ]
    ]

  alias JidoHpc.Safety.PathGuard

  @impl true
  def run(%{path: path, content: content} = params, ctx) do
    with {:ok, abs} <- PathGuard.validate(path, ctx),
         :ok <- ensure_parent(abs, params.mkdir_p?),
         :ok <- guard_overwrite(abs, params.overwrite),
         :ok <- File.write(abs, content) do
      {:ok, %{path: abs, byte_size: byte_size(content)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_parent(abs, true) do
    parent = Path.dirname(abs)

    case File.mkdir_p(parent) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, parent, reason}}
    end
  end

  defp ensure_parent(abs, false) do
    parent = Path.dirname(abs)

    if File.dir?(parent) do
      :ok
    else
      {:error, {:parent_missing, parent}}
    end
  end

  defp guard_overwrite(_abs, true), do: :ok

  defp guard_overwrite(abs, false) do
    if File.exists?(abs) do
      {:error, {:exists, abs}}
    else
      :ok
    end
  end
end
