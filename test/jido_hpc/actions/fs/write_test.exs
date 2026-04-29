defmodule JidoHpc.Actions.FS.WriteTest do
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.FS.Write

  setup do
    root =
      Path.join(System.tmp_dir!(), "jido_hpc_fs_write_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    prev = Application.get_env(:jido_hpc, :path_allowlist)
    Application.put_env(:jido_hpc, :path_allowlist, [root])

    on_exit(fn ->
      File.rm_rf!(root)
      if prev, do: Application.put_env(:jido_hpc, :path_allowlist, prev)
    end)

    {:ok, root: root}
  end

  test "writes a new file", %{root: root} do
    path = Path.join(root, "out.txt")

    assert {:ok, %{byte_size: 5}} =
             Write.run(
               %{path: path, content: "hello", overwrite: false, mkdir_p?: false},
               %{}
             )

    assert File.read!(path) == "hello"
  end

  test "refuses to overwrite by default", %{root: root} do
    path = Path.join(root, "existing.txt")
    File.write!(path, "old")

    assert {:error, {:exists, ^path}} =
             Write.run(
               %{path: path, content: "new", overwrite: false, mkdir_p?: false},
               %{}
             )

    assert File.read!(path) == "old"
  end

  test "overwrites when allowed", %{root: root} do
    path = Path.join(root, "existing.txt")
    File.write!(path, "old")

    assert {:ok, _} =
             Write.run(
               %{path: path, content: "new", overwrite: true, mkdir_p?: false},
               %{}
             )

    assert File.read!(path) == "new"
  end

  test "refuses missing parent without mkdir_p?", %{root: root} do
    path = Path.join([root, "nope", "deep", "x.txt"])

    assert {:error, {:parent_missing, _}} =
             Write.run(
               %{path: path, content: "x", overwrite: false, mkdir_p?: false},
               %{}
             )
  end

  test "creates parent dirs with mkdir_p?", %{root: root} do
    path = Path.join([root, "a", "b", "c", "x.txt"])

    assert {:ok, _} =
             Write.run(
               %{path: path, content: "x", overwrite: false, mkdir_p?: true},
               %{}
             )

    assert File.read!(path) == "x"
  end

  test "rejects path outside allowlist" do
    assert {:error, {:outside_allowlist, _}} =
             Write.run(
               %{path: "/tmp/forbidden.txt", content: "x", overwrite: false, mkdir_p?: false},
               %{}
             )
  end
end
