defmodule JidoHpc.Slurm.CLITest do
  # not async — flips global :slurm_cli config
  use ExUnit.Case, async: false

  alias JidoHpc.Slurm.CLI
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

  test "dispatches to the configured impl" do
    SlurmCLIStub.expect(:sbatch, fn _path, _spec ->
      {:ok, %{job_id: "777", stdout: ""}}
    end)

    assert {:ok, %{job_id: "777"}} = CLI.sbatch("/tmp/script.sh", nil)
  end

  test "squeue + sacct + scancel + sinfo all route through impl" do
    SlurmCLIStub.expect(:squeue, fn _ -> {:ok, [%{job_id: "1", state: "RUNNING"}]} end)
    SlurmCLIStub.expect(:sacct, fn _, _ -> {:ok, [%{job_id: "1", state: "COMPLETED"}]} end)
    SlurmCLIStub.expect(:scancel, fn _, _ -> :ok end)
    SlurmCLIStub.expect(:sinfo, fn _ -> {:ok, [%{partition: "main"}]} end)

    assert {:ok, [%{job_id: "1"}]} = CLI.squeue([])
    assert {:ok, [%{state: "COMPLETED"}]} = CLI.sacct("1", [])
    assert :ok = CLI.scancel("1")
    assert {:ok, [%{partition: "main"}]} = CLI.sinfo()
  end

  test "scontrol_show_job optional callback returns :not_implemented for impls without it" do
    defmodule MinimalImpl do
      @behaviour JidoHpc.Slurm.CLI
      @impl true
      def sbatch(_p, _s), do: :ok
      @impl true
      def squeue(_), do: :ok
      @impl true
      def sacct(_, _), do: :ok
      @impl true
      def scancel(_, _), do: :ok
      @impl true
      def sinfo(_), do: :ok
    end

    Application.put_env(:jido_hpc, :slurm_cli, MinimalImpl)
    assert {:error, :not_implemented} = CLI.scontrol_show_job("1")
  end
end
