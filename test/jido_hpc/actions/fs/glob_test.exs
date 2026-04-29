defmodule JidoHpc.Actions.FS.GlobTest do
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.FS.Glob

  setup do
    root =
      Path.join(System.tmp_dir!(), "jido_hpc_fs_glob_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "")
    File.write!(Path.join(root, "lib/b.ex"), "")
    File.write!(Path.join(root, "lib/c.exs"), "")
    File.write!(Path.join(root, "README.md"), "")

    prev = Application.get_env(:jido_hpc, :path_allowlist)
    Application.put_env(:jido_hpc, :path_allowlist, [root])

    on_exit(fn ->
      File.rm_rf!(root)
      if prev, do: Application.put_env(:jido_hpc, :path_allowlist, prev)
    end)

    {:ok, root: root}
  end

  test "expands a glob", %{root: root} do
    assert {:ok, %{paths: paths, truncated?: false}} =
             Glob.run(%{root: root, pattern: "lib/*.ex", max_results: 100}, %{})

    paths = Enum.sort(paths)
    assert paths == Enum.sort([Path.join(root, "lib/a.ex"), Path.join(root, "lib/b.ex")])
  end

  test "respects max_results and reports truncation", %{root: root} do
    assert {:ok, %{paths: paths, truncated?: true}} =
             Glob.run(%{root: root, pattern: "lib/*", max_results: 1}, %{})

    assert length(paths) == 1
  end

  test "rejects root outside allowlist" do
    assert {:error, {:outside_allowlist, _}} =
             Glob.run(%{root: "/etc", pattern: "*", max_results: 100}, %{})
  end
end
