defmodule JidoHpc.Slurm.ScriptTest do
  use ExUnit.Case, async: true

  alias JidoHpc.Slurm.{JobSpec, Script}

  defp spec(extras \\ %{}) do
    {:ok, s} =
      Map.merge(
        %{
          name: "demo",
          time: "01:00:00",
          workdir: "/tmp/demo",
          command: ["echo", "hi"]
        },
        extras
      )
      |> JobSpec.new()

    s
  end

  test "shebang and core directives present" do
    {:ok, script} = Script.render(spec())

    assert String.starts_with?(script, "#!/bin/bash\n")
    assert script =~ "#SBATCH --job-name=demo\n"
    assert script =~ "#SBATCH --time=01:00:00\n"
    assert script =~ "#SBATCH --nodes=1\n"
    assert script =~ "#SBATCH --ntasks=1\n"
    assert script =~ "#SBATCH --cpus-per-task=1\n"
    assert script =~ "#SBATCH --chdir=/tmp/demo\n"
    assert script =~ "#SBATCH --output=logs/%x-%j.out\n"
    assert script =~ "#SBATCH --error=logs/%x-%j.err\n"
    assert script =~ "set -euo pipefail\n"
  end

  test "omits unset optional directives" do
    {:ok, script} = Script.render(spec())

    refute script =~ "--mem"
    refute script =~ "--partition"
    refute script =~ "--account"
    refute script =~ "--qos"
    refute script =~ "--array"
    refute script =~ "--dependency"
    refute script =~ "--gres"
  end

  test "renders gpu request" do
    {:ok, script} = Script.render(spec(%{gpus: 4}))
    assert script =~ "#SBATCH --gres=gpu:4\n"
  end

  test "renders modules in order" do
    {:ok, script} =
      Script.render(spec(%{modules: ["cuda/12.1", "openmpi/4.1"]}))

    assert script =~ "module load cuda/12.1\n"
    assert script =~ "module load openmpi/4.1\n"
    # cuda comes first
    {idx_cuda, _} = :binary.match(script, "module load cuda")
    {idx_mpi, _} = :binary.match(script, "module load openmpi")
    assert idx_cuda < idx_mpi
  end

  test "exports env vars sorted, with single-quote bash quoting" do
    {:ok, script} = Script.render(spec(%{env: %{"BETA" => "two", "ALPHA" => "one"}}))

    {idx_a, _} = :binary.match(script, "ALPHA")
    {idx_b, _} = :binary.match(script, "BETA")
    assert idx_a < idx_b
    assert script =~ "export ALPHA='one'\n"
    assert script =~ "export BETA='two'\n"
  end

  test "single-quote escapes embedded apostrophes" do
    {:ok, script} = Script.render(spec(%{env: %{"FOO" => "it's"}}))
    # `it's` becomes `'it'\''s'`
    assert script =~ "export FOO='it'\\''s'\n"
  end

  test "command argv is bash-quoted, one shell line" do
    {:ok, script} =
      Script.render(spec(%{command: ["python", "train.py", "--lr", "1e-3"]}))

    assert script =~ "'python' 'train.py' '--lr' '1e-3'\n"
  end

  test "rejects values containing control characters" do
    {:ok, raw} =
      JobSpec.new(%{
        name: "x",
        time: "01:00:00",
        workdir: "/tmp/x",
        command: ["echo"]
      })

    bad = %{raw | env: %{"FOO" => <<7>>}}
    assert {:error, {:unrenderable, _}} = Script.render(bad)
  end

  test "no ambient env leakage — does not read OS environment" do
    # Render with an env set in the test process; the renderer must NOT
    # interpolate anything from the live OS environment.
    System.put_env("JIDO_HPC_TEST_LEAK", "secret-value")
    {:ok, script} = Script.render(spec())
    System.delete_env("JIDO_HPC_TEST_LEAK")

    refute script =~ "JIDO_HPC_TEST_LEAK"
    refute script =~ "secret-value"
  end
end
