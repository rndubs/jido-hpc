defmodule JidoHpc.AuditLogTest do
  use ExUnit.Case, async: false

  alias JidoHpc.AuditLog

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_hpc_audit_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "audit.log")
    Application.put_env(:jido_hpc, :audit_log_path, path)

    on_exit(fn ->
      Application.delete_env(:jido_hpc, :audit_log_path)
      File.rm_rf!(dir)
    end)

    %{path: path}
  end

  test "append/1 writes a single line with required fields", %{path: path} do
    {:ok, ^path} =
      AuditLog.append(%{
        event: :slurm_submit,
        session_id: "abc",
        prompt_hash: "deadbeef",
        job_id: "12345",
        sbatch_path: "/tmp/foo.sh",
        autonomy: :autonomous,
        submitted: true
      })

    contents = File.read!(path)
    [line] = String.split(contents, "\n", trim: true)

    decoded = Jason.decode!(line)
    assert decoded["event"] == "slurm_submit"
    assert decoded["session_id"] == "abc"
    assert decoded["job_id"] == "12345"
    assert decoded["submitted"] == true
    assert is_binary(decoded["ts"])
  end

  test "append/1 auto-stamps :ts if not provided", %{path: path} do
    {:ok, _} = AuditLog.append(%{event: :slurm_submit})

    line = File.read!(path) |> String.trim()
    assert %{"ts" => ts} = Jason.decode!(line)
    assert {:ok, _, _} = DateTime.from_iso8601(ts)
  end

  test "multiple appends produce one line each", %{path: path} do
    for i <- 1..3 do
      AuditLog.append(%{event: :slurm_submit, job_id: "#{i}"})
    end

    lines = File.read!(path) |> String.split("\n", trim: true)
    assert length(lines) == 3
  end

  test "log file gets chmod 0600", %{path: path} do
    AuditLog.append(%{event: :slurm_submit})

    %File.Stat{mode: mode} = File.stat!(path)
    # Mask down to permission bits.
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "hash_prompt/1 is deterministic and 64 hex chars" do
    h = AuditLog.hash_prompt("hello world")
    assert h == AuditLog.hash_prompt("hello world")
    assert String.length(h) == 64
    assert h =~ ~r/^[0-9a-f]{64}$/
  end

  test "new_session_id/0 yields distinct values" do
    a = AuditLog.new_session_id()
    b = AuditLog.new_session_id()
    assert a != b
    assert is_binary(a) and byte_size(a) > 8
  end

  test "concurrent appends never interleave half-lines", %{path: path} do
    # 30 tasks racing each other through the writer. If the
    # `:global` lock id is wrong (e.g. includes self() so each pid
    # gets a different id), partial writes will leave at least one
    # malformed line and the JSON decode below will explode.
    1..30
    |> Enum.map(fn i ->
      Task.async(fn -> AuditLog.append(%{event: :slurm_submit, job_id: "#{i}"}) end)
    end)
    |> Enum.each(&Task.await(&1, 5_000))

    lines = File.read!(path) |> String.split("\n", trim: true)
    assert length(lines) == 30

    decoded = Enum.map(lines, &Jason.decode!/1)
    seen_ids = decoded |> Enum.map(& &1["job_id"]) |> Enum.sort()
    assert seen_ids == Enum.map(1..30, &"#{&1}") |> Enum.sort()
  end
end
