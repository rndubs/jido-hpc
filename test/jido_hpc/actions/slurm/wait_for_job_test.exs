defmodule JidoHpc.Actions.Slurm.WaitForJobTest do
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.Slurm.WaitForJob
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

  test "returns immediately on terminal squeue state" do
    SlurmCLIStub.expect(:squeue, fn _ ->
      {:ok, [%{job_id: "1", state: "COMPLETED"}]}
    end)

    assert {:ok, %{state: :completed, raw_state: "COMPLETED"}} =
             WaitForJob.run(
               %{job_id: "1", poll_interval_ms: 10, timeout_ms: 1_000},
               %{}
             )
  end

  test "polls until state becomes terminal" do
    SlurmCLIStub.expect(:squeue, fn _ ->
      {:ok, [%{job_id: "1", state: "RUNNING"}]}
    end)

    SlurmCLIStub.expect(:squeue, fn _ ->
      {:ok, [%{job_id: "1", state: "COMPLETED"}]}
    end)

    assert {:ok, %{state: :completed}} =
             WaitForJob.run(
               %{job_id: "1", poll_interval_ms: 10, timeout_ms: 1_000},
               %{}
             )
  end

  test "falls back to sacct when job leaves the queue" do
    SlurmCLIStub.expect(:squeue, fn _ -> {:ok, []} end)

    SlurmCLIStub.expect(:sacct, fn "1", _ ->
      {:ok, [%{job_id: "1", state: "COMPLETED", exit_code: 0}]}
    end)

    assert {:ok, %{state: :completed, fields: %{exit_code: 0}}} =
             WaitForJob.run(
               %{job_id: "1", poll_interval_ms: 10, timeout_ms: 1_000},
               %{}
             )
  end

  test "returns timeout when job stays non-terminal" do
    # Queue many "RUNNING" responses; the timeout should fire first.
    for _ <- 1..50 do
      SlurmCLIStub.expect(:squeue, fn _ ->
        {:ok, [%{job_id: "1", state: "RUNNING"}]}
      end)
    end

    assert {:error, :timeout} =
             WaitForJob.run(
               %{job_id: "1", poll_interval_ms: 5, timeout_ms: 30},
               %{}
             )
  end

  test "rejects malformed job ids" do
    assert {:error, {:invalid_job_id, _}} =
             WaitForJob.run(
               %{job_id: "x; rm -rf", poll_interval_ms: 10, timeout_ms: 100},
               %{}
             )
  end
end
