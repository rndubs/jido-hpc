defmodule JidoHpc.Safety.PathGuardTest do
  use ExUnit.Case, async: true

  alias JidoHpc.Safety.PathGuard

  setup do
    root =
      Path.join(System.tmp_dir!(), "jido_hpc_path_guard_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "sub"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "happy path" do
    test "accepts a path inside the allowlist", %{root: root} do
      child = Path.join(root, "a.txt")
      assert {:ok, ^child} = PathGuard.validate(child, roots: [root])
    end

    test "accepts the root itself", %{root: root} do
      assert {:ok, ^root} = PathGuard.validate(root, roots: [root])
    end

    test "accepts a deeply nested path", %{root: root} do
      deep = Path.join([root, "sub", "deeper", "x.txt"])
      assert {:ok, ^deep} = PathGuard.validate(deep, roots: [root])
    end

    test "expands a relative path against cwd if cwd is allowlisted" do
      cwd = File.cwd!()
      assert {:ok, abs} = PathGuard.validate("README.md", roots: [cwd])
      assert abs == Path.expand("README.md")
    end
  end

  describe "rejections" do
    test "non-binary input", %{root: root} do
      assert {:error, {:invalid_path, :not_a_string}} =
               PathGuard.validate(:atom, roots: [root])

      assert {:error, {:invalid_path, :not_a_string}} =
               PathGuard.validate(123, roots: [root])
    end

    test "empty / whitespace-only", %{root: root} do
      assert {:error, {:invalid_path, :empty}} = PathGuard.validate("", roots: [root])
      assert {:error, {:invalid_path, :empty}} = PathGuard.validate("   ", roots: [root])
    end

    test "literal `..` segment in input", %{root: root} do
      bad = Path.join(root, "../etc/passwd")
      assert {:error, {:invalid_path, :dotdot_segment}} = PathGuard.validate(bad, roots: [root])
    end

    test "rejects path with leading ..", %{root: root} do
      assert {:error, {:invalid_path, :dotdot_segment}} =
               PathGuard.validate("../sneaky", roots: [root])
    end

    test "null byte", %{root: root} do
      assert {:error, {:invalid_path, :null_byte}} =
               PathGuard.validate("a" <> <<0>> <> "b", roots: [root])
    end

    test "outside allowlist", %{root: root} do
      assert {:error, {:outside_allowlist, "/etc/passwd"}} =
               PathGuard.validate("/etc/passwd", roots: [root])
    end

    test "empty allowlist rejects everything" do
      assert {:error, {:outside_allowlist, _}} =
               PathGuard.validate("/anywhere", roots: [])
    end

    test "prefix-but-not-segment is rejected" do
      # /tmp/foo allowed; /tmp/foobar must NOT match
      tmp_root = Path.join(System.tmp_dir!(), "guard_root_#{:erlang.unique_integer([:positive])}")
      sibling = tmp_root <> "_sibling"

      assert {:error, {:outside_allowlist, _}} =
               PathGuard.validate(sibling, roots: [tmp_root])
    end
  end

  describe "validate!/2" do
    test "raises on rejection", %{root: root} do
      assert_raise ArgumentError, ~r/path rejected/, fn ->
        PathGuard.validate!("/etc/passwd", roots: [root])
      end
    end

    test "returns absolute path on success", %{root: root} do
      child = Path.join(root, "ok.txt")
      assert PathGuard.validate!(child, roots: [root]) == child
    end
  end

  describe "roots/1" do
    test "expands configured roots" do
      assert PathGuard.roots(roots: ["/tmp"]) == ["/tmp"]
      assert PathGuard.roots(roots: ["/tmp", "/var"]) == ["/tmp", "/var"]
    end

    test "drops empties" do
      assert PathGuard.roots(roots: ["", "/tmp"]) == ["/tmp"]
    end
  end
end
