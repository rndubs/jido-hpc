defmodule JidoHpc.Test.REPLDispatcherStub do
  @moduledoc """
  Test stub for `JidoHpc.REPL.Dispatcher`.

  Stash a queue of `ask_stream` responses (each a list of canned
  events plus an `await` result), plus per-action results for
  `run_action`, in the process dictionary of the test process. When
  the REPL invokes the dispatcher, it pops the next pre-canned
  response.

  Keeps tests deterministic without booting an LLM.
  """

  @behaviour JidoHpc.REPL.Dispatcher

  @stream_key {__MODULE__, :stream_q}
  @action_key {__MODULE__, :action_q}

  def expect_stream(events, await_result \\ {:ok, %{}}) do
    queue = Process.get(@stream_key, [])
    Process.put(@stream_key, queue ++ [{events, await_result}])
    :ok
  end

  def expect_action(action, response) do
    queue = Process.get(@action_key, [])
    Process.put(@action_key, queue ++ [{action, response}])
    :ok
  end

  def reset do
    Process.delete(@stream_key)
    Process.delete(@action_key)
    :ok
  end

  @impl true
  def ask_stream(_agent, _prompt, _opts) do
    case Process.get(@stream_key, []) do
      [{events, _await} = head | rest] ->
        Process.put(@stream_key, rest)
        request = {:fake_request, head}
        {:ok, %{request: request, events: events}}

      [] ->
        {:error, :no_stub}
    end
  end

  @impl true
  def await(_agent, {:fake_request, {_events, await_result}}) do
    await_result
  end

  @impl true
  def run_action(action, _params, _ctx) do
    case Process.get(@action_key, []) do
      [{^action, response} | rest] ->
        Process.put(@action_key, rest)
        response

      [{other, _} | _] ->
        {:error, {:unexpected_action, action, expected: other}}

      [] ->
        {:error, {:no_action_stub, action}}
    end
  end
end
