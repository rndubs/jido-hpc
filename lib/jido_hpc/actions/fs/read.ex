defmodule JidoHpc.Actions.FS.Read do
  @moduledoc """
  Read a file from disk after path-allowlist validation.

  Returns `{:ok, %{path, content, byte_size, truncated?}}`. If the file is
  larger than `max_bytes`, content is truncated and `truncated?` is true —
  the LLM should request specific byte ranges in a follow-up call.
  """

  use Jido.Action,
    name: "fs_read",
    description: "Read a UTF-8 file from disk. The path must lie under an allowlisted root.",
    schema: [
      path: [type: :string, required: true, doc: "Absolute or relative path."],
      max_bytes: [
        type: :pos_integer,
        default: 256 * 1024,
        doc: "Cap on bytes returned. Files larger than this are truncated."
      ],
      offset: [
        type: :non_neg_integer,
        default: 0,
        doc: "Byte offset to start reading from (default 0)."
      ]
    ]

  alias JidoHpc.Safety.PathGuard

  @impl true
  def run(%{path: path, max_bytes: max_bytes, offset: offset}, _context) do
    with {:ok, abs} <- PathGuard.validate(path),
         {:ok, %File.Stat{size: total_size}} <- File.stat(abs),
         {:ok, fd} <- File.open(abs, [:read, :binary]) do
      try do
        :ok = seek(fd, offset)
        to_read = min(max_bytes, max(total_size - offset, 0))

        content =
          case IO.binread(fd, to_read) do
            :eof -> ""
            data when is_binary(data) -> data
            {:error, reason} -> throw({:read_error, reason})
          end

        truncated? = offset + byte_size(content) < total_size

        {:ok,
         %{
           path: abs,
           content: content,
           byte_size: byte_size(content),
           total_size: total_size,
           offset: offset,
           truncated?: truncated?
         }}
      catch
        {:read_error, reason} -> {:error, {:read_failed, reason}}
      after
        File.close(fd)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp seek(_fd, 0), do: :ok

  defp seek(fd, offset) do
    case :file.position(fd, offset) do
      {:ok, _} -> :ok
      err -> throw({:read_error, err})
    end
  end
end
