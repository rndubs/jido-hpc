defmodule JidoHpc.Actions.FS.GrepTest do
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.FS.Grep

  setup do
    root =
      Path.join(System.tmp_dir!(), "jido_hpc_fs_grep_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "a.txt"), "alpha beta\nfoobar baz\n")
    File.write!(Path.join(root, "sub/b.txt"), "another foobar line\n")
    File.write!(Path.join(root, "sub/c.txt"), "no needle here\n")

    prev = Application.get_env(:jido_hpc, :path_allowlist)
    Application.put_env(:jido_hpc, :path_allowlist, [root])

    on_exit(fn ->
      File.rm_rf!(root)
      if prev, do: Application.put_env(:jido_hpc, :path_allowlist, prev)
    end)

    {:ok, root: root}
  end

  test "finds matches across nested files", %{root: root} do
    assert {:ok, %{matches: matches, files_scanned: scanned}} =
             Grep.run(
               %{
                 pattern: "foobar",
                 path: root,
                 glob: "**/*",
                 max_matches: 200,
                 max_file_bytes: 1_048_576,
                 case_insensitive: false
               },
               %{}
             )

    assert scanned >= 3
    assert length(matches) == 2
    paths = Enum.map(matches, & &1.path) |> Enum.sort()
    assert paths == Enum.sort([Path.join(root, "a.txt"), Path.join(root, "sub/b.txt")])
  end

  test "case-insensitive matching", %{root: root} do
    File.write!(Path.join(root, "case.txt"), "FooBar\n")

    assert {:ok, %{matches: matches}} =
             Grep.run(
               %{
                 pattern: "foobar",
                 path: root,
                 glob: "case.txt",
                 max_matches: 10,
                 max_file_bytes: 1_048_576,
                 case_insensitive: true
               },
               %{}
             )

    assert length(matches) == 1
  end

  test "respects max_matches and reports truncation", %{root: root} do
    assert {:ok, %{matches: matches, truncated?: true}} =
             Grep.run(
               %{
                 pattern: "foobar",
                 path: root,
                 glob: "**/*",
                 max_matches: 1,
                 max_file_bytes: 1_048_576,
                 case_insensitive: false
               },
               %{}
             )

    assert length(matches) == 1
  end

  test "rejects path outside allowlist" do
    assert {:error, {:outside_allowlist, _}} =
             Grep.run(
               %{
                 pattern: "x",
                 path: "/etc",
                 glob: "**/*",
                 max_matches: 10,
                 max_file_bytes: 1_048_576,
                 case_insensitive: false
               },
               %{}
             )
  end
end
