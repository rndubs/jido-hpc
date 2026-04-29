defmodule JidoHpc.Actions.FS.LsTest do
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.FS.Ls

  setup do
    root =
      Path.join(System.tmp_dir!(), "jido_hpc_fs_ls_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "visible.txt"), "x")
    File.write!(Path.join(root, ".hidden"), "y")
    File.mkdir_p!(Path.join(root, "subdir"))

    prev = Application.get_env(:jido_hpc, :path_allowlist)
    Application.put_env(:jido_hpc, :path_allowlist, [root])

    on_exit(fn ->
      File.rm_rf!(root)
      if prev, do: Application.put_env(:jido_hpc, :path_allowlist, prev)
    end)

    {:ok, root: root}
  end

  test "lists non-hidden entries by default", %{root: root} do
    assert {:ok, %{entries: entries}} =
             Ls.run(%{path: root, include_hidden?: false}, %{})

    names = Enum.map(entries, & &1.name) |> Enum.sort()
    assert names == ["subdir", "visible.txt"]
  end

  test "includes hidden entries when asked", %{root: root} do
    assert {:ok, %{entries: entries}} =
             Ls.run(%{path: root, include_hidden?: true}, %{})

    names = Enum.map(entries, & &1.name)
    assert ".hidden" in names
  end

  test "entries include type, size, mtime", %{root: root} do
    assert {:ok, %{entries: entries}} =
             Ls.run(%{path: root, include_hidden?: false}, %{})

    file_entry = Enum.find(entries, &(&1.name == "visible.txt"))
    assert file_entry.type == :regular
    assert file_entry.size == 1
    assert is_tuple(file_entry.mtime)

    dir_entry = Enum.find(entries, &(&1.name == "subdir"))
    assert dir_entry.type == :directory
  end

  test "rejects path outside allowlist" do
    assert {:error, {:outside_allowlist, _}} =
             Ls.run(%{path: "/etc", include_hidden?: false}, %{})
  end
end
