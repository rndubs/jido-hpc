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

  test "ShellSkill is loadable" do
    assert Code.ensure_loaded?(JidoHpc.Skills.ShellSkill)
  end

  test "GitSkill is loadable" do
    assert Code.ensure_loaded?(JidoHpc.Skills.GitSkill)
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
end
