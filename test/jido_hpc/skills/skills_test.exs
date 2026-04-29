defmodule JidoHpc.SkillsTest do
  use ExUnit.Case, async: true

  # Smoke test: skill modules compile and their declared actions are
  # all themselves loadable and implement the Jido.Action contract
  # (i.e. export run/2). This catches typos in the actions: list at
  # plugin definition time.

  @shell_actions [
    JidoHpc.Actions.Bash.Run,
    JidoHpc.Actions.FS.Read,
    JidoHpc.Actions.FS.Write,
    JidoHpc.Actions.FS.Edit,
    JidoHpc.Actions.FS.Grep,
    JidoHpc.Actions.FS.Ls,
    JidoHpc.Actions.FS.Glob
  ]

  @git_actions [
    JidoHpc.Actions.Git.Status,
    JidoHpc.Actions.Git.Diff,
    JidoHpc.Actions.Git.Log
  ]

  @slurm_actions [
    JidoHpc.Actions.Slurm.Submit,
    JidoHpc.Actions.Slurm.Cancel,
    JidoHpc.Actions.Slurm.Status,
    JidoHpc.Actions.Slurm.Sacct,
    JidoHpc.Actions.Slurm.Sinfo,
    JidoHpc.Actions.Slurm.TemplateScript,
    JidoHpc.Actions.Slurm.WaitForJob
  ]

  test "ShellSkill is loadable" do
    assert Code.ensure_loaded?(JidoHpc.Skills.ShellSkill)
  end

  test "GitSkill is loadable" do
    assert Code.ensure_loaded?(JidoHpc.Skills.GitSkill)
  end

  test "SlurmSkill is loadable" do
    assert Code.ensure_loaded?(JidoHpc.Skills.SlurmSkill)
  end

  test "every shell action implements run/2" do
    for mod <- @shell_actions do
      assert Code.ensure_loaded?(mod), "#{inspect(mod)} not loadable"
      assert function_exported?(mod, :run, 2), "#{inspect(mod)} missing run/2"
    end
  end

  test "every git action implements run/2" do
    for mod <- @git_actions do
      assert Code.ensure_loaded?(mod), "#{inspect(mod)} not loadable"
      assert function_exported?(mod, :run, 2), "#{inspect(mod)} missing run/2"
    end
  end

  test "every slurm action implements run/2" do
    for mod <- @slurm_actions do
      assert Code.ensure_loaded?(mod), "#{inspect(mod)} not loadable"
      assert function_exported?(mod, :run, 2), "#{inspect(mod)} missing run/2"
    end
  end

  test "SlurmSkill exposes a child_spec/1 for the SlurmJobSensor" do
    assert function_exported?(JidoHpc.Skills.SlurmSkill, :child_spec, 1)

    spec = JidoHpc.Skills.SlurmSkill.child_spec([])
    assert %{id: JidoHpc.Sensors.SlurmJobSensor, start: {_, _, _}} = spec
  end
end
