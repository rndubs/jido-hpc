defmodule JidoHpc.Agents.CodingAgentTest do
  use ExUnit.Case, async: true

  # Static smoke test: the agent module compiles, and the three skills
  # we expect it to bundle are themselves loadable. We don't spin up
  # the agent or call an LLM here — that's `:smoke`-tagged and lives in
  # `test/integration/llm_smoke_test.exs`.

  @skills [
    JidoHpc.Skills.SlurmSkill,
    JidoHpc.Skills.ShellSkill,
    JidoHpc.Skills.GitSkill
  ]

  test "CodingAgent module is loadable" do
    assert Code.ensure_loaded?(JidoHpc.Agents.CodingAgent)
  end

  test "all wired skills are loadable" do
    for mod <- @skills do
      assert Code.ensure_loaded?(mod), "#{inspect(mod)} not loadable"
    end
  end
end
