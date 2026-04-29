defmodule JidoHpc.Actions.FS.ReadTest do
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.FS.Read

  setup do
    root = Path.join(System.tmp_dir!(), "jido_hpc_fs_read_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:jido_hpc, :path_allowlist)
    Application.put_env(:jido_hpc, :path_allowlist, [root])

    on_exit(fn ->
      File.rm_rf!(root)
      if prev, do: Application.put_env(:jido_hpc, :path_allowlist, prev)
    end)

    {:ok, root: root}
  end

  test "reads a file under the allowlist", %{root: root} do
    path = Path.join(root, "hello.txt")
    File.write!(path, "world")

    assert {:ok, %{content: "world", byte_size: 5, truncated?: false}} =
             Read.run(%{path: path, max_bytes: 256, offset: 0}, %{})
  end

  test "rejects path outside allowlist" do
    assert {:error, {:outside_allowlist, _}} =
             Read.run(%{path: "/etc/passwd", max_bytes: 256, offset: 0}, %{})
  end

  test "rejects `..` segment" do
    assert {:error, {:invalid_path, :dotdot_segment}} =
             Read.run(%{path: "/tmp/../etc/passwd", max_bytes: 256, offset: 0}, %{})
  end

  test "truncates large files", %{root: root} do
    path = Path.join(root, "big.txt")
    File.write!(path, String.duplicate("x", 1000))

    assert {:ok, %{byte_size: 100, truncated?: true, total_size: 1000}} =
             Read.run(%{path: path, max_bytes: 100, offset: 0}, %{})
  end

  test "honors offset", %{root: root} do
    path = Path.join(root, "off.txt")
    File.write!(path, "0123456789")

    assert {:ok, %{content: "456789", offset: 4, truncated?: false}} =
             Read.run(%{path: path, max_bytes: 256, offset: 4}, %{})
  end
end
