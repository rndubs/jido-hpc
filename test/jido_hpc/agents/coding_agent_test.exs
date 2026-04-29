defmodule JidoHpc.Agents.CodingAgentTest do
  # async: false — booting the agent starts JidoHpc.Sensors.SlurmJobSensor
  # under its default registered name; running two boot tests in parallel
  # would collide on the name.
  use ExUnit.Case, async: false

  @skills [
    JidoHpc.Skills.SlurmSkill,
    JidoHpc.Skills.ShellSkill,
    JidoHpc.Skills.GitSkill
  ]

  describe "static contract" do
    test "CodingAgent module is loadable" do
      assert Code.ensure_loaded?(JidoHpc.Agents.CodingAgent)
    end

    test "all wired skills are loadable" do
      for mod <- @skills do
        assert Code.ensure_loaded?(mod), "#{inspect(mod)} not loadable"
      end
    end
  end

  describe "live boot under JidoHpc.Jido" do
    # Boots the agent through the real Jido supervision tree. No LLM
    # round-trip — that path is exercised by the :smoke-tagged
    # integration test once an ANTHROPIC_API_KEY is available. What
    # this test asserts is the wiring contract: skill plugins resolve,
    # post_init runs, plugin children (the SlurmJobSensor) start.

    setup do
      id = "coding-agent-boot-test-#{System.unique_integer([:positive])}"
      {:ok, pid} = JidoHpc.Jido.start_agent(JidoHpc.Agents.CodingAgent, id: id)

      on_exit(fn ->
        if Process.alive?(pid), do: JidoHpc.Jido.stop_agent(pid)
      end)

      {:ok, pid: pid, id: id}
    end

    test "agent process is alive and registered", %{pid: pid, id: id} do
      assert Process.alive?(pid)
      assert JidoHpc.Jido.whereis(id) == pid
    end

    test "post_init populates State with the right agent module", %{pid: pid} do
      {:ok, state} = Jido.AgentServer.state(pid)
      assert state.agent_module == JidoHpc.Agents.CodingAgent
      assert is_map(state.children)
    end

    test "SlurmSkill plugin started a SlurmJobSensor child", %{pid: pid} do
      {:ok, state} = Jido.AgentServer.state(pid)

      sensor_tag = {:plugin, JidoHpc.Skills.SlurmSkill, JidoHpc.Sensors.SlurmJobSensor}
      child = Map.get(state.children, sensor_tag)

      assert child,
             "expected SlurmJobSensor child under tag #{inspect(sensor_tag)}, " <>
               "saw children: #{inspect(Map.keys(state.children))}"

      assert Process.alive?(child.pid)
    end

    test "agent.actions/0 resolves skill plugin actions through real Jido" do
      # @plugin_actions is populated at compile time by the Jido.Agent
      # macro from the union of all plugin actions. If skill plugin
      # resolution breaks, this list goes empty or loses entries.
      actions = JidoHpc.Agents.CodingAgent.actions()

      # A representative from each skill must be present.
      assert JidoHpc.Actions.Slurm.Submit in actions
      assert JidoHpc.Actions.FS.Read in actions
      assert JidoHpc.Actions.Git.Status in actions
    end
  end
end
