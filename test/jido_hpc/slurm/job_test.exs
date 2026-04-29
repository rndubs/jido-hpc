defmodule JidoHpc.Slurm.JobTest do
  use ExUnit.Case, async: true

  alias JidoHpc.Slurm.Job

  describe "parse_state/1" do
    test "maps common active states" do
      assert Job.parse_state("PENDING") == :pending
      assert Job.parse_state("RUNNING") == :running
      assert Job.parse_state("COMPLETING") == :running
      assert Job.parse_state("CONFIGURING") == :pending
    end

    test "maps terminal states" do
      assert Job.parse_state("COMPLETED") == :completed
      assert Job.parse_state("FAILED") == :failed
      assert Job.parse_state("TIMEOUT") == :timeout
      assert Job.parse_state("OUT_OF_MEMORY") == :oom
      assert Job.parse_state("CANCELLED") == :cancelled
      assert Job.parse_state("CANCELLED+") == :cancelled
      assert Job.parse_state("NODE_FAIL") == :node_fail
      assert Job.parse_state("PREEMPTED") == :preempted
    end

    test "is case-insensitive and trims whitespace" do
      assert Job.parse_state(" running ") == :running
      assert Job.parse_state("Pending") == :pending
    end

    test "unknown maps to :unknown" do
      assert Job.parse_state("WAT") == :unknown
      assert Job.parse_state(nil) == :unknown
    end
  end

  describe "terminal?/1" do
    test "terminal states" do
      for s <- ~w(completed failed timeout oom cancelled node_fail preempted)a do
        assert Job.terminal?(s)
      end
    end

    test "non-terminal states" do
      for s <- ~w(pending running unknown)a do
        refute Job.terminal?(s)
      end
    end

    test "accepts a Job struct" do
      job = Job.new("1", state: :completed)
      assert Job.terminal?(job)
      refute Job.terminal?(Job.new("2", state: :running))
    end
  end

  describe "update/2" do
    test "transitions on state change" do
      job = Job.new("123", state: :pending)
      {next, transitioned?} = Job.update(job, %{state: "RUNNING"})

      assert next.state == :running
      assert next.raw_state == "RUNNING"
      assert transitioned?
    end

    test "no transition when state unchanged" do
      job = Job.new("123", state: :running, raw_state: "RUNNING")
      {next, transitioned?} = Job.update(job, %{state: "RUNNING"})

      assert next.state == :running
      refute transitioned?
    end

    test "merges accounting fields" do
      job = Job.new("1", state: :running)

      {next, _} =
        Job.update(job, %{
          state: "COMPLETED",
          exit_code: 0,
          elapsed: "00:05:12",
          max_rss: "2048K"
        })

      assert next.exit_code == 0
      assert next.elapsed == "00:05:12"
      assert next.max_rss == "2048K"
    end

    test "string keys also work" do
      job = Job.new("1")
      {next, _} = Job.update(job, %{"state" => "FAILED"})
      assert next.state == :failed
    end
  end
end
