defmodule JidoHpc.Safety.CmdGuardTest do
  use ExUnit.Case, async: true

  alias JidoHpc.Safety.CmdGuard

  @allow ~w(ls cat git grep rg sbatch squeue)

  describe "happy path" do
    test "accepts allowlisted command + arg list" do
      assert {:ok, {"ls", ["-la", "/tmp"]}} =
               CmdGuard.validate("ls", ["-la", "/tmp"], allowlist: @allow)
    end

    test "accepts an absolute path whose basename is allowlisted" do
      assert {:ok, {"/usr/bin/git", ["status"]}} =
               CmdGuard.validate("/usr/bin/git", ["status"], allowlist: @allow)
    end

    test "accepts empty arg list" do
      assert {:ok, {"ls", []}} = CmdGuard.validate("ls", [], allowlist: @allow)
    end
  end

  describe "command rejections" do
    test "non-binary cmd" do
      assert {:error, {:invalid_cmd, :not_a_string}} =
               CmdGuard.validate(:ls, [], allowlist: @allow)
    end

    test "empty cmd" do
      assert {:error, {:invalid_cmd, :empty}} =
               CmdGuard.validate("", [], allowlist: @allow)
    end

    test "cmd with shell metacharacters" do
      for bad <- ["ls;rm", "ls|cat", "ls&", "ls`whoami`", "$(ls)", "ls\nrm", "ls>out"] do
        assert {:error, {:invalid_cmd, :shell_metacharacter}} =
                 CmdGuard.validate(bad, [], allowlist: @allow),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "cmd with NUL byte" do
      assert {:error, {:invalid_cmd, :null_byte}} =
               CmdGuard.validate("ls" <> <<0>>, [], allowlist: @allow)
    end

    test "cmd not on allowlist" do
      assert {:error, {:not_allowlisted, "rm"}} =
               CmdGuard.validate("rm", ["-rf", "/"], allowlist: @allow)
    end

    test "absolute path with non-allowlisted basename rejected" do
      assert {:error, {:not_allowlisted, "rm"}} =
               CmdGuard.validate("/bin/rm", [], allowlist: @allow)
    end
  end

  describe "args rejections" do
    test "args not a list" do
      assert {:error, {:invalid_args, :not_a_list}} =
               CmdGuard.validate("ls", "-la", allowlist: @allow)
    end

    test "non-string arg element" do
      assert {:error, {:invalid_args, :non_string_element}} =
               CmdGuard.validate("ls", [:dash_l], allowlist: @allow)

      assert {:error, {:invalid_args, :non_string_element}} =
               CmdGuard.validate("ls", [["nested"]], allowlist: @allow)
    end

    test "NUL byte in arg" do
      assert {:error, {:invalid_args, :null_byte}} =
               CmdGuard.validate("ls", ["a" <> <<0>>], allowlist: @allow)
    end
  end

  describe "validate!/3" do
    test "returns the pair on success" do
      assert CmdGuard.validate!("ls", ["-la"], allowlist: @allow) == {"ls", ["-la"]}
    end

    test "raises on failure" do
      assert_raise ArgumentError, ~r/command rejected/, fn ->
        CmdGuard.validate!("rm", [], allowlist: @allow)
      end
    end
  end

  describe "allowlist/1" do
    test "reads from app config when no opt" do
      assert is_list(CmdGuard.allowlist())
    end

    test "honors :allowlist opt" do
      assert CmdGuard.allowlist(allowlist: ["foo"]) == ["foo"]
    end
  end
end
