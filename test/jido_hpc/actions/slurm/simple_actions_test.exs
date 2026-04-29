defmodule JidoHpc.Actions.Slurm.SimpleActionsTest do
  @moduledoc """
  Combined tests for the read-only Slurm actions (Status, Sacct, Sinfo, Cancel).
  Each piggybacks on the same stubbed `JidoHpc.Slurm.CLI`.
  """

  use ExUnit.Case, async: false

  alias JidoHpc.Actions.Slurm.{Cancel, Sacct, Sinfo, Status}
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

  describe "Status" do
    test "returns parsed jobs with state_atom" do
      SlurmCLIStub.expect(:squeue, fn _opts ->
        {:ok,
         [
           %{job_id: "1", state: "RUNNING", partition: "main"},
           %{job_id: "2", state: "PENDING", partition: "main"}
         ]}
      end)

      assert {:ok, %{jobs: [j1, j2], count: 2}} =
               Status.run(%{user: nil, partition: nil, job: nil}, %{})

      assert j1.state_atom == :running
      assert j2.state_atom == :pending
    end

    test "passes filters to CLI" do
      SlurmCLIStub.expect(:squeue, fn opts ->
        assert opts[:user] == "alice"
        assert opts[:partition] == "gpu"
        {:ok, []}
      end)

      assert {:ok, %{count: 0}} =
               Status.run(%{user: "alice", partition: "gpu", job: nil}, %{})
    end
  end

  describe "Sacct" do
    test "returns parsed records with state_atom" do
      SlurmCLIStub.expect(:sacct, fn "12345", _opts ->
        {:ok, [%{job_id: "12345", state: "COMPLETED", exit_code: 0, elapsed: "00:05:00"}]}
      end)

      assert {:ok, %{records: [r], count: 1, job_id: "12345"}} =
               Sacct.run(%{job_id: "12345"}, %{})

      assert r.state_atom == :completed
      assert r.exit_code == 0
    end

    test "rejects malformed job ids without calling CLI" do
      assert {:error, {:invalid_job_id, "rm -rf"}} =
               Sacct.run(%{job_id: "rm -rf"}, %{})
    end
  end

  describe "Sinfo" do
    test "returns partitions" do
      SlurmCLIStub.expect(:sinfo, fn _ ->
        {:ok, [%{partition: "main", avail: "up"}, %{partition: "gpu", avail: "up"}]}
      end)

      assert {:ok, %{partitions: parts, count: 2}} = Sinfo.run(%{}, %{})
      assert Enum.at(parts, 0).partition == "main"
    end
  end

  describe "Cancel" do
    test "passes a clean job id through" do
      SlurmCLIStub.expect(:scancel, fn "555", _opts -> :ok end)

      assert {:ok, %{job_id: "555", cancelled: true}} =
               Cancel.run(%{job_id: "555"}, %{})
    end

    test "accepts array job ids" do
      SlurmCLIStub.expect(:scancel, fn "555_3", _opts -> :ok end)
      assert {:ok, %{cancelled: true}} = Cancel.run(%{job_id: "555_3"}, %{})
    end

    test "rejects shell-meta in job id without calling CLI" do
      assert {:error, {:invalid_job_id, _}} =
               Cancel.run(%{job_id: "555; rm -rf /"}, %{})
    end
  end
end
