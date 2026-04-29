defmodule JidoHpc.Actions.Slurm.TemplateScriptTest do
  use ExUnit.Case, async: false

  alias JidoHpc.Actions.Slurm.TemplateScript

  setup do
    prev = Application.get_env(:jido_hpc, :path_allowlist)
    root = Path.join(System.tmp_dir!(), "jido_hpc_tmpl_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:jido_hpc, :path_allowlist, [root])

    on_exit(fn ->
      File.rm_rf!(root)
      if prev, do: Application.put_env(:jido_hpc, :path_allowlist, prev)
    end)

    {:ok, root: root}
  end

  test "renders a script for a valid spec", %{root: root} do
    params = %{
      name: "demo",
      time: "00:30:00",
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
      qos: nil
    }

    assert {:ok, %{spec: spec, script: script, workdir: wd}} =
             TemplateScript.run(params, %{})

    assert wd == root
    assert spec.name == "demo"
    assert script =~ "#SBATCH --job-name=demo\n"
    assert script =~ "'echo' 'ok'\n"
  end

  test "rejects workdir outside the allowlist" do
    assert {:error, {:outside_allowlist, _}} =
             TemplateScript.run(
               %{
                 name: "x",
                 time: "01:00:00",
                 workdir: "/etc",
                 command: ["true"],
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
                 qos: nil
               },
               %{}
             )
  end
end
