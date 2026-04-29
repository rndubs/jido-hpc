defmodule JidoHpc.Sensors.SlurmJobSensorTest do
  use ExUnit.Case, async: false

  alias JidoHpc.Sensors.SlurmJobSensor
  alias JidoHpc.Test.SlurmCLIStub

  setup do
    SlurmCLIStub.setup()
    Application.put_env(:jido_hpc, :slurm_cli, SlurmCLIStub)

    on_exit(fn ->
      Application.delete_env(:jido_hpc, :slurm_cli)
      SlurmCLIStub.reset()
    end)

    :ok
  end

  defp start_sensor(opts) do
    test_pid = self()

    dispatch = fn topic, payload ->
      send(test_pid, {:signal, topic, payload})
      :ok
    end

    name = :"sensor_#{System.unique_integer([:positive])}"

    full_opts =
      Keyword.merge(
        [dispatch: dispatch, poll_interval_ms: 60_000, name: name],
        opts
      )

    {:ok, pid} = SlurmJobSensor.start_link(full_opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  test "tracking + state-change emits a transition signal" do
    name = start_sensor(tracked_jobs: ["123"])

    SlurmCLIStub.expect(:squeue, fn _opts ->
      {:ok, [%{job_id: "123", state: "RUNNING"}]}
    end)

    SlurmJobSensor.poll_now(name)

    assert_receive {:signal, "slurm.job.transition",
                    %{job: %{state: :running}, previous_state: :pending}},
                   1_000
  end

  test "terminal state emits a terminal signal and untracks the job" do
    name = start_sensor(tracked_jobs: ["999"])

    SlurmCLIStub.expect(:squeue, fn _opts ->
      {:ok, [%{job_id: "999", state: "COMPLETED"}]}
    end)

    SlurmJobSensor.poll_now(name)

    assert_receive {:signal, "slurm.job.completed", %{job: %{state: :completed}}}, 1_000

    refute Map.has_key?(SlurmJobSensor.tracked(name), "999")
  end

  test "no signal when state is unchanged" do
    name = start_sensor(tracked_jobs: ["1"])

    # First poll: pending -> running (transition)
    SlurmCLIStub.expect(:squeue, fn _ -> {:ok, [%{job_id: "1", state: "RUNNING"}]} end)
    SlurmJobSensor.poll_now(name)
    assert_receive {:signal, "slurm.job.transition", _}, 1_000

    # Second poll: still running (no transition)
    SlurmCLIStub.expect(:squeue, fn _ -> {:ok, [%{job_id: "1", state: "RUNNING"}]} end)
    SlurmJobSensor.poll_now(name)
    refute_receive {:signal, _, _}, 100
  end

  test "falls back to sacct when job leaves the queue" do
    name = start_sensor(tracked_jobs: ["7"])

    SlurmCLIStub.expect(:squeue, fn _ -> {:ok, []} end)

    SlurmCLIStub.expect(:sacct, fn "7", _ ->
      {:ok, [%{job_id: "7", state: "COMPLETED", exit_code: 0}]}
    end)

    SlurmJobSensor.poll_now(name)
    assert_receive {:signal, "slurm.job.completed", _}, 1_000
  end

  test "track/untrack manage the tracked set" do
    name = start_sensor([])

    SlurmJobSensor.track(name, "555")
    Process.sleep(20)
    assert Map.has_key?(SlurmJobSensor.tracked(name), "555")

    SlurmJobSensor.untrack(name, "555")
    Process.sleep(20)
    refute Map.has_key?(SlurmJobSensor.tracked(name), "555")
  end
end
