defmodule JidoHpc.Actions.FS.EditTest do
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.FS.Edit

  setup do
    root =
      Path.join(System.tmp_dir!(), "jido_hpc_fs_edit_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    prev = Application.get_env(:jido_hpc, :path_allowlist)
    Application.put_env(:jido_hpc, :path_allowlist, [root])

    on_exit(fn ->
      File.rm_rf!(root)
      if prev, do: Application.put_env(:jido_hpc, :path_allowlist, prev)
    end)

    {:ok, root: root}
  end

  test "replaces a unique substring", %{root: root} do
    path = Path.join(root, "f.txt")
    File.write!(path, "hello world\n")

    assert {:ok, %{replacements: 1}} =
             Edit.run(
               %{path: path, old_string: "world", new_string: "Elixir", replace_all: false},
               %{}
             )

    assert File.read!(path) == "hello Elixir\n"
  end

  test "rejects non-unique match without replace_all", %{root: root} do
    path = Path.join(root, "f.txt")
    File.write!(path, "abc abc abc")

    assert {:error, {:not_unique, 3}} =
             Edit.run(
               %{path: path, old_string: "abc", new_string: "x", replace_all: false},
               %{}
             )

    assert File.read!(path) == "abc abc abc"
  end

  test "replaces all when replace_all is true", %{root: root} do
    path = Path.join(root, "f.txt")
    File.write!(path, "abc abc abc")

    assert {:ok, %{replacements: 3}} =
             Edit.run(
               %{path: path, old_string: "abc", new_string: "x", replace_all: true},
               %{}
             )

    assert File.read!(path) == "x x x"
  end

  test "errors when old_string is not present", %{root: root} do
    path = Path.join(root, "f.txt")
    File.write!(path, "hello")

    assert {:error, {:not_found, "world"}} =
             Edit.run(
               %{path: path, old_string: "world", new_string: "x", replace_all: false},
               %{}
             )
  end

  test "rejects empty old_string", %{root: root} do
    path = Path.join(root, "f.txt")
    File.write!(path, "x")

    assert {:error, {:invalid_edit, :empty_old_string}} =
             Edit.run(
               %{path: path, old_string: "", new_string: "y", replace_all: false},
               %{}
             )
  end

  test "rejects no-op edit", %{root: root} do
    path = Path.join(root, "f.txt")
    File.write!(path, "abc")

    assert {:error, {:invalid_edit, :no_op}} =
             Edit.run(
               %{path: path, old_string: "abc", new_string: "abc", replace_all: false},
               %{}
             )
  end

  test "rejects path outside allowlist" do
    assert {:error, {:outside_allowlist, _}} =
             Edit.run(
               %{path: "/etc/hosts", old_string: "x", new_string: "y", replace_all: false},
               %{}
             )
  end
end
