defmodule JidoHpc.Actions.GitActionsTest do
  # Touches app env, so async: false.
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.Git.{Diff, Log, Status}

  @moduletag :git

  setup_all do
    unless System.find_executable("git") do
      raise "git not found on PATH; tests require git"
    end

    :ok
  end

  setup do
    prev_cmd = Application.get_env(:jido_hpc, :cmd_allowlist)
    prev_path = Application.get_env(:jido_hpc, :path_allowlist)

    repo =
      Path.join(System.tmp_dir!(), "jido_hpc_git_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(repo)

    Application.put_env(:jido_hpc, :cmd_allowlist, ~w(git))
    Application.put_env(:jido_hpc, :path_allowlist, [repo])

    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test"])
    git!(repo, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(repo, "README.md"), "hello\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-q", "-m", "initial"])

    on_exit(fn ->
      File.rm_rf!(repo)
      if prev_cmd, do: Application.put_env(:jido_hpc, :cmd_allowlist, prev_cmd)
      if prev_path, do: Application.put_env(:jido_hpc, :path_allowlist, prev_path)
    end)

    {:ok, repo: repo}
  end

  describe "Status" do
    test "clean repo", %{repo: repo} do
      assert {:ok, %{stdout: out, exit_status: 0, cwd: ^repo}} =
               Status.run(%{cwd: repo}, %{})

      assert String.contains?(out, "## main")
      refute Regex.match?(~r/^.M /m, out)
    end

    test "dirty repo", %{repo: repo} do
      File.write!(Path.join(repo, "README.md"), "hello\nworld\n")

      assert {:ok, %{stdout: out}} = Status.run(%{cwd: repo}, %{})
      assert Regex.match?(~r/^ M README\.md/m, out)
    end

    test "rejects cwd outside allowlist" do
      assert {:error, {:outside_allowlist, _}} = Status.run(%{cwd: "/etc"}, %{})
    end
  end

  describe "Diff" do
    test "working-tree diff", %{repo: repo} do
      File.write!(Path.join(repo, "README.md"), "hello\nworld\n")

      assert {:ok, %{stdout: out, exit_status: 0}} =
               Diff.run(
                 %{cwd: repo, rev: nil, staged?: false, paths: [], max_bytes: 1024},
                 %{}
               )

      assert String.contains?(out, "+world")
    end

    test "staged diff", %{repo: repo} do
      File.write!(Path.join(repo, "README.md"), "hello\nworld\n")
      git!(repo, ["add", "README.md"])

      assert {:ok, %{stdout: out}} =
               Diff.run(
                 %{cwd: repo, rev: nil, staged?: true, paths: [], max_bytes: 1024},
                 %{}
               )

      assert String.contains?(out, "+world")
    end

    test "rejects path outside allowlist" do
      assert {:error, {:outside_allowlist, _}} =
               Diff.run(
                 %{cwd: "/etc", rev: nil, staged?: false, paths: [], max_bytes: 1024},
                 %{}
               )
    end
  end

  describe "Log" do
    test "parses entries", %{repo: repo} do
      assert {:ok, %{entries: [entry], exit_status: 0}} =
               Log.run(%{cwd: repo, limit: 20, rev: nil, paths: []}, %{})

      assert entry.subject == "initial"
      assert entry.author == "Test"
      assert entry.email == "test@example.com"
      assert is_binary(entry.hash) and byte_size(entry.hash) == 40
    end

    test "rejects path outside allowlist" do
      assert {:error, {:outside_allowlist, _}} =
               Log.run(%{cwd: "/etc", limit: 5, rev: nil, paths: []}, %{})
    end
  end

  defp git!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{out}"
    end
  end
end
