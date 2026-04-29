defmodule JidoHpc.Actions.Bash.RunTest do
  # async: false because we're touching app env (cmd_allowlist) and the
  # global RateLimiter.
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.Bash.Run

  setup do
    prev_cmd = Application.get_env(:jido_hpc, :cmd_allowlist)
    prev_path = Application.get_env(:jido_hpc, :path_allowlist)

    root =
      Path.join(System.tmp_dir!(), "jido_hpc_bash_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    Application.put_env(:jido_hpc, :cmd_allowlist, ~w(ls echo true false))
    Application.put_env(:jido_hpc, :path_allowlist, [root])

    on_exit(fn ->
      File.rm_rf!(root)
      if prev_cmd, do: Application.put_env(:jido_hpc, :cmd_allowlist, prev_cmd)
      if prev_path, do: Application.put_env(:jido_hpc, :path_allowlist, prev_path)
    end)

    {:ok, root: root}
  end

  describe "happy path" do
    test "runs ls in an allowlisted cwd", %{root: root} do
      File.write!(Path.join(root, "marker"), "")

      assert {:ok, %{stdout: out, exit_status: 0, cmd: "ls"}} =
               Run.run(%{cmd: "ls", args: [], cd: root, timeout_ms: 5_000}, %{})

      assert String.contains?(out, "marker")
    end

    test "runs without cwd" do
      assert {:ok, %{stdout: "hi\n", exit_status: 0}} =
               Run.run(%{cmd: "echo", args: ["hi"], cd: nil, timeout_ms: 5_000}, %{})
    end

    test "non-zero exit is reported, not raised" do
      assert {:ok, %{exit_status: 1}} =
               Run.run(%{cmd: "false", args: [], cd: nil, timeout_ms: 5_000}, %{})
    end
  end

  describe "rejections" do
    test "non-allowlisted command" do
      assert {:error, {:not_allowlisted, "rm"}} =
               Run.run(%{cmd: "rm", args: ["-rf"], cd: nil, timeout_ms: 5_000}, %{})
    end

    test "shell-meta in cmd" do
      assert {:error, {:invalid_cmd, :shell_metacharacter}} =
               Run.run(%{cmd: "ls;rm", args: [], cd: nil, timeout_ms: 5_000}, %{})
    end

    test "cwd outside allowlist" do
      assert {:error, {:outside_allowlist, _}} =
               Run.run(%{cmd: "ls", args: [], cd: "/etc", timeout_ms: 5_000}, %{})
    end

    test "cwd with `..` segment" do
      assert {:error, {:invalid_path, :dotdot_segment}} =
               Run.run(%{cmd: "ls", args: [], cd: "/tmp/../etc", timeout_ms: 5_000}, %{})
    end
  end
end
