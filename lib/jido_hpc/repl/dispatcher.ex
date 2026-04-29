defmodule JidoHpc.REPL.Dispatcher do
  @moduledoc """
  Behaviour adapting the REPL's three operations
  (`ask_stream/3`, `await/2`, `run_action/3`) to whatever backend is
  driving the agent.

  The default implementation, `JidoHpc.REPL.Dispatcher.Live`, calls the
  generated functions on the agent module
  (`Jido.AI.Agent.ask_stream/3` etc.). Tests can swap in a stub so the
  loop runs without booting an LLM.
  """

  @callback ask_stream(agent :: module(), prompt :: String.t(), opts :: keyword()) ::
              {:ok, %{request: any(), events: Enumerable.t()}} | {:error, term()}

  @callback await(agent :: module(), request :: any()) ::
              {:ok, term()} | {:error, term()}

  @callback run_action(action :: module(), params :: map(), ctx :: map()) ::
              {:ok, term()} | {:error, term()}
end

defmodule JidoHpc.REPL.Dispatcher.Live do
  @moduledoc """
  Production dispatcher. Forwards to `Jido.AI.Agent.ask_stream/3` /
  `await/2` on the agent module, and runs actions directly via their
  `run/2` callback.

  Lazily resolves these functions so the module compiles cleanly even
  before `jido_ai` is on the path.
  """

  @behaviour JidoHpc.REPL.Dispatcher

  @impl true
  def ask_stream(agent, prompt, opts) do
    if function_exported?(agent, :ask_stream, 3) do
      apply(agent, :ask_stream, [agent, prompt, opts])
    else
      {:error, {:not_loaded, {agent, :ask_stream, 3}}}
    end
  end

  @impl true
  def await(agent, request) do
    if function_exported?(agent, :await, 2) do
      apply(agent, :await, [agent, request])
    else
      {:error, {:not_loaded, {agent, :await, 2}}}
    end
  end

  @impl true
  def run_action(action, params, ctx) do
    apply(action, :run, [params, ctx])
  end
end
