defmodule JidoHpc.Integration.LLMSmokeTest do
  @moduledoc """
  End-to-end smoke test that the Jido + jido_ai + req_llm wiring can
  actually call an LLM. Skipped by default; run with:

      ANTHROPIC_API_KEY=... mix test --include smoke test/integration/llm_smoke_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :smoke

  test "Jido.AI.ask returns a non-empty response" do
    assert {:ok, response} = Jido.AI.ask("Reply with the single word OK.")
    assert is_binary(response)
    assert String.length(response) > 0
  end
end
