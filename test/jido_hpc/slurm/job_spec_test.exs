defmodule JidoHpc.Slurm.JobSpecTest do
  use ExUnit.Case, async: true

  alias JidoHpc.Slurm.JobSpec

  describe "new/1 happy path" do
    test "applies defaults to optional fields" do
      assert {:ok, spec} =
               JobSpec.new(%{
                 name: "demo",
                 time: "01:00:00",
                 workdir: "/tmp/demo",
                 command: ["echo", "hi"]
               })

      assert spec.nodes == 1
      assert spec.ntasks == 1
      assert spec.cpus_per_task == 1
      assert spec.modules == []
      assert spec.env == %{}
      assert spec.output == "logs/%x-%j.out"
      assert spec.error == "logs/%x-%j.err"
      assert spec.partition == nil
      assert spec.gpus == nil
    end

    test "accepts string keys as well as atom keys" do
      assert {:ok, spec} =
               JobSpec.new(%{
                 "name" => "x",
                 "time" => "00:30:00",
                 "workdir" => "/tmp/x",
                 "command" => ["true"]
               })

      assert spec.name == "x"
    end

    test "preserves caller-supplied values" do
      assert {:ok, spec} =
               JobSpec.new(
                 name: "ml",
                 time: "1-12:00:00",
                 nodes: 2,
                 ntasks: 16,
                 cpus_per_task: 4,
                 mem: "64G",
                 gpus: 4,
                 partition: "gpu",
                 modules: ["cuda/12.1", "openmpi/4.1"],
                 env: %{"FOO" => "bar"},
                 workdir: "/scratch/me/run",
                 command: ["python", "train.py"]
               )

      assert spec.nodes == 2
      assert spec.gpus == 4
      assert spec.modules == ["cuda/12.1", "openmpi/4.1"]
      assert spec.env == %{"FOO" => "bar"}
      assert spec.command == ["python", "train.py"]
    end
  end

  describe "new/1 rejections" do
    @base %{name: "x", time: "01:00:00", workdir: "/tmp", command: ["true"]}

    test "missing required name" do
      assert {:error, {:invalid, :name, _}} =
               JobSpec.new(Map.delete(@base, :name))
    end

    test "empty command" do
      assert {:error, {:invalid, :command, :required_non_empty_list}} =
               JobSpec.new(%{@base | command: []})
    end

    test "non-string command element" do
      assert {:error, {:invalid, :command, _}} =
               JobSpec.new(%{@base | command: [:python]})
    end

    test "shell-meta in name" do
      assert {:error, {:invalid, :name, :unsafe_characters}} =
               JobSpec.new(%{@base | name: "ok;rm"})
    end

    test "bogus time format" do
      assert {:error, {:invalid, :time, :unrecognized_format}} =
               JobSpec.new(%{@base | time: "an hour"})
    end

    test "valid time variants" do
      for t <- ["01:00:00", "1-00:00:00", "1-12:30:45", "120"] do
        assert {:ok, _} = JobSpec.new(%{@base | time: t})
      end
    end

    test "non-positive nodes" do
      assert {:error, {:invalid, :nodes, _}} = JobSpec.new(Map.put(@base, :nodes, 0))
      assert {:error, {:invalid, :nodes, _}} = JobSpec.new(Map.put(@base, :nodes, -1))
    end

    test "negative gpus" do
      assert {:error, {:invalid, :gpus, _}} = JobSpec.new(Map.put(@base, :gpus, -1))
    end

    test "env with bad key" do
      assert {:error, {:invalid, :env, {:bad_key, _}}} =
               JobSpec.new(Map.put(@base, :env, %{"1FOO" => "x"}))
    end

    test "env with newline value" do
      assert {:error, {:invalid, :env, {:newline_in_value, _}}} =
               JobSpec.new(Map.put(@base, :env, %{"FOO" => "a\nb"}))
    end

    test "bogus mem format" do
      assert {:error, {:invalid, :mem, _}} =
               JobSpec.new(Map.put(@base, :mem, "lots"))
    end
  end
end
