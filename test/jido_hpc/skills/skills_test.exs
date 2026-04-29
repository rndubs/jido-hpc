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
    Code.ensure_loaded(JidoHpc.Skills.SlurmSkill)
    assert function_exported?(JidoHpc.Skills.SlurmSkill, :child_spec, 1)

    # Jido passes config as a map at runtime; accept the keyword form
    # too for test/script ergonomics.
    for config <- [%{}, []] do
      spec = JidoHpc.Skills.SlurmSkill.child_spec(config)
      assert %{id: JidoHpc.Sensors.SlurmJobSensor, start: {_, _, _}} = spec
    end
  end

  test "CodingAgent's hand-listed tools match the union of skill actions" do
    # The Jido.AI.Agent macro requires `tools:` as a literal list at
    # the call site (it can't evaluate function calls or module
    # attributes). To avoid drift between the hand-listed tools and
    # what each skill actually exposes, this test asserts the two
    # sets are identical. If a skill gains or drops an action, this
    # test fails until the agent's tools: list is updated.
    skill_actions =
      [JidoHpc.Skills.SlurmSkill, JidoHpc.Skills.ShellSkill, JidoHpc.Skills.GitSkill]
      |> Enum.flat_map(& &1.actions())
      |> MapSet.new()

    agent_tools = MapSet.new(JidoHpc.Agents.CodingAgent.actions())

    only_in_skills = MapSet.difference(skill_actions, agent_tools) |> MapSet.to_list()
    only_in_agent = MapSet.difference(agent_tools, skill_actions) |> MapSet.to_list()

    assert only_in_skills == [],
           "skill actions not advertised by the agent's tools: list: #{inspect(only_in_skills)}"

    assert only_in_agent == [],
           "agent tools that no skill exposes: #{inspect(only_in_agent)}"
  end
end
