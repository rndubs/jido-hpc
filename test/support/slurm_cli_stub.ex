defmodule JidoHpc.Test.SlurmCLIStub do
  @moduledoc """
  Test stub for `JidoHpc.Slurm.CLI`.

  Expectations are stored in a public ETS table keyed by `{owner_pid, fn}`.
  The "owner" is the test process that called `expect/2`. When the stub is
  invoked from a process spawned inside the test (sensor, GenServer, ...),
  the call walks `$callers` to find the owner, so expectations queued in
  the test process are still consumed.

  ## Usage

      setup do
        JidoHpc.Test.SlurmCLIStub.setup()
        Application.put_env(:jido_hpc, :slurm_cli, JidoHpc.Test.SlurmCLIStub)

        on_exit(fn ->
          Application.delete_env(:jido_hpc, :slurm_cli)
        end)

        :ok
      end

      JidoHpc.Test.SlurmCLIStub.expect(:sbatch, fn _path, _spec ->
        {:ok, %{job_id: "12345", stdout: "Submitted batch job 12345\\n"}}
      end)

  Multiple expectations for the same function are consumed FIFO.
  """

  @behaviour JidoHpc.Slurm.CLI

  @table :jido_hpc_slurm_cli_stub

  # ---- Test API ---------------------------------------------------------

  @doc """
  Ensure the stub's ETS table exists and that the calling test process is
  registered as a potential owner. Call from `setup`.
  """
  def setup do
    table()
    :ets.insert(@table, {{:owner, self()}, true})
    :ok
  end

  @doc "Queue a stubbed response for `fun_name`."
  def expect(fun_name, impl) when is_atom(fun_name) and is_function(impl) do
    table()
    pid = self()
    key = {pid, fun_name}

    queue =
      case :ets.lookup(@table, key) do
        [{^key, q}] -> q ++ [impl]
        [] -> [impl]
      end

    :ets.insert(@table, {key, queue})
    :ets.insert(@table, {{:owner, pid}, true})
    :ok
  end

  @doc "Clear all queued expectations for the current test process."
  def reset do
    table()
    pid = self()
    :ets.match_delete(@table, {{pid, :_}, :_})
    :ets.delete(@table, {:owner, pid})
    :ok
  end

  # ---- CLI behaviour ----------------------------------------------------

  @impl true
  def sbatch(script_path, spec), do: pop_and_call(:sbatch, [script_path, spec])

  @impl true
  def squeue(opts), do: pop_and_call(:squeue, [opts])

  @impl true
  def sacct(job_id, opts), do: pop_and_call(:sacct, [job_id, opts])

  @impl true
  def scancel(job_id, opts), do: pop_and_call(:scancel, [job_id, opts])

  @impl true
  def sinfo(opts), do: pop_and_call(:sinfo, [opts])

  @impl true
  def scontrol_show_job(job_id, opts), do: pop_and_call(:scontrol_show_job, [job_id, opts])

  defp pop_and_call(fun, args) do
    case pop(fun) do
      {:ok, impl} ->
        {_, arity} = :erlang.fun_info(impl, :arity)
        apply(impl, Enum.take(args, arity))

      :empty ->
        {:error, {:no_stub, fun}}
    end
  end

  defp pop(fun_name) do
    candidates =
      ([self() | Process.get(:"$callers", [])] ++ all_owners())
      |> Enum.uniq()

    Enum.reduce_while(candidates, :empty, fn pid, _acc ->
      key = {pid, fun_name}

      case :ets.lookup(@table, key) do
        [{^key, [next | rest]}] ->
          :ets.insert(@table, {key, rest})
          {:halt, {:ok, next}}

        _ ->
          {:cont, :empty}
      end
    end)
  end

  defp all_owners do
    @table
    |> :ets.match({{:owner, :"$1"}, true})
    |> List.flatten()
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:public, :named_table, :set, read_concurrency: true])

      tid ->
        tid
    end
  end
end
