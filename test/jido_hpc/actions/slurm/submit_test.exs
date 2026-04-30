defmodule JidoHpc.Actions.Slurm.SubmitTest do
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.Slurm.Submit
  alias JidoHpc.Test.SlurmCLIStub

  setup do
    prev_path = Application.get_env(:jido_hpc, :path_allowlist)
    prev_cli = Application.get_env(:jido_hpc, :slurm_cli)
    prev_aut = Application.get_env(:jido_hpc, :autonomy)

    root = Path.join(System.tmp_dir!(), "jido_hpc_submit_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)

    Application.put_env(:jido_hpc, :path_allowlist, [root])
    Application.put_env(:jido_hpc, :slurm_cli, SlurmCLIStub)
    SlurmCLIStub.setup()

    on_exit(fn ->
      File.rm_rf!(root)
      if prev_path, do: Application.put_env(:jido_hpc, :path_allowlist, prev_path)
      if prev_cli, do: Application.put_env(:jido_hpc, :slurm_cli, prev_cli)
      if prev_aut, do: Application.put_env(:jido_hpc, :autonomy, prev_aut)
    end)

    {:ok, root: root}
  end

  defp base(root) do
    %{
      name: "demo",
      time: "01:00:00",
      workdir: root,
      command: ["echo", "ok"],
      nodes: 1,
      ntasks: 1,
      cpus_per_task: 1,
      mem: nil,
      gpus: nil,
      partition: nil,
      modules: [],
      env: %{},
      array: nil,
      dependency: nil,
      output: nil,
      error: nil,
      account: nil,
      qos: nil,
      confirm: false,
      autonomy: nil
    }
  end

  test "confirm_on_submit writes script but does not call sbatch", %{root: root} do
    Application.put_env(:jido_hpc, :autonomy, :confirm_on_submit)

    assert {:ok,
            %{
              submitted: false,
              job_id: nil,
              reason: :awaiting_confirmation,
              script_path: path,
              autonomy: :confirm_on_submit
            }} = Submit.run(base(root), %{})

    assert File.exists?(path)
    assert path =~ Path.join([root, ".jido_hpc", "sbatch"])
    assert File.read!(path) =~ "#SBATCH --job-name=demo"
  end

  test "autonomous mode submits via the CLI stub", %{root: root} do
    Application.put_env(:jido_hpc, :autonomy, :autonomous)

    SlurmCLIStub.expect(:sbatch, fn path, _spec ->
      assert File.exists?(path)
      {:ok, %{job_id: "9001", stdout: "Submitted batch job 9001\n"}}
    end)

    assert {:ok, %{submitted: true, job_id: "9001", script_path: _path}} =
             Submit.run(base(root), %{})
  end

  test "confirm: true overrides confirm_on_submit autonomy", %{root: root} do
    Application.put_env(:jido_hpc, :autonomy, :confirm_on_submit)

    SlurmCLIStub.expect(:sbatch, fn _path, _spec ->
      {:ok, %{job_id: "5", stdout: ""}}
    end)

    params = %{base(root) | confirm: true}

    assert {:ok, %{submitted: true, job_id: "5"}} = Submit.run(params, %{})
  end

  test "per-call autonomy override wins over app env", %{root: root} do
    Application.put_env(:jido_hpc, :autonomy, :autonomous)

    params = %{base(root) | autonomy: :confirm_on_submit}
    assert {:ok, %{submitted: false}} = Submit.run(params, %{})
  end

  test "sbatch failure surfaces as error", %{root: root} do
    Application.put_env(:jido_hpc, :autonomy, :autonomous)

    SlurmCLIStub.expect(:sbatch, fn _path, _spec ->
      {:error, {:nonzero_exit, 1, "Invalid partition\n"}}
    end)

    assert {:error, {:sbatch_failed, _}} = Submit.run(base(root), %{})
  end

  test "registers a successful submission with the SlurmJobSensor (Phase 4.6)", %{root: root} do
    Application.put_env(:jido_hpc, :autonomy, :autonomous)

    SlurmCLIStub.expect(:sbatch, fn _path, _spec ->
      {:ok, %{job_id: "424242", stdout: ""}}
    end)

    # Boot a sensor under a one-off name so we don't collide with any
    # globally-running JidoHpc.Sensors.SlurmJobSensor (e.g. from another
    # test that booted CodingAgent). Submit picks the name up from
    # ctx[:state][:slurm][:sensor_name].
    sensor_name = :"submit_test_sensor_#{:erlang.unique_integer([:positive])}"

    {:ok, sensor_pid} =
      JidoHpc.Sensors.SlurmJobSensor.start_link(name: sensor_name, poll_interval_ms: 86_400_000)

    on_exit(fn -> if Process.alive?(sensor_pid), do: GenServer.stop(sensor_pid) end)

    ctx = %{state: %{slurm: %{sensor_name: sensor_name}}}

    assert {:ok, %{job_id: "424242"}} = Submit.run(base(root), ctx)

    # cast/track is async — give the cast a moment to process.
    tracked = JidoHpc.Sensors.SlurmJobSensor.tracked(sensor_name)
    assert Map.has_key?(tracked, "424242")
  end

  test "writes an audit-log entry on submission", %{root: root} do
    Application.put_env(:jido_hpc, :autonomy, :autonomous)

    audit_path = Path.join(root, "audit.log")
    Application.put_env(:jido_hpc, :audit_log_path, audit_path)

    on_exit(fn ->
      Application.put_env(:jido_hpc, :audit_log_path, :disabled)
    end)

    SlurmCLIStub.expect(:sbatch, fn _path, _spec ->
      {:ok, %{job_id: "777", stdout: ""}}
    end)

    params =
      Map.merge(base(root), %{
        session_id: "sess-1",
        prompt_hash: "hashy"
      })

    assert {:ok, %{job_id: "777"}} = Submit.run(params, %{})

    assert File.exists?(audit_path)
    contents = File.read!(audit_path)
    assert contents =~ "sess-1"
    assert contents =~ "hashy"
    assert contents =~ "777"
  end
end
