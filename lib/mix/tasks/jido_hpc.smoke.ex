defmodule Mix.Tasks.JidoHpc.Smoke do
  @shortdoc "End-to-end smoke: drive the CodingAgent with a real LLM"

  @moduledoc """
  Live, one-shot smoke test: boots the application, starts the
  `JidoHpc.Agents.CodingAgent`, and asks it to read a known scratch
  file and report what's inside. Verifies the agent actually invoked
  a `fs_*` tool and that the output mentions the secret token from
  the file.

      ANTHROPIC_API_KEY=sk-ant-... mix jido_hpc.smoke

  Exits 0 on success, 1 on failure. Prints the raw `ask_sync` result
  on completion so a human can eyeball the LLM's reasoning trace.

  This task is intentionally separate from `mix test` because it
  costs API tokens. It satisfies the Phase 1 "manual smoke: agent
  edits a file via tool calls" item in `plan.md`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    case JidoHpc.Config.api_key_status() do
      {:ok, %{provider: provider, source: source}} ->
        Mix.shell().info("[smoke] LLM provider #{provider} key from #{source}")
        run_smoke()

      {:error, msg} ->
        Mix.shell().error(msg)
        exit({:shutdown, 1})
    end
  end

  defp run_smoke do
    {scratch_path, token} = create_scratch_file()
    Mix.shell().info("[smoke] scratch file: #{scratch_path}")

    {:ok, pid} = Jido.AgentServer.start(agent: JidoHpc.Agents.CodingAgent)

    prompt = """
    Read the file at #{scratch_path} using the fs_read tool, then tell me
    what secret token it contains. Reply with just the token.
    """

    Mix.shell().info("[smoke] asking agent...")

    case JidoHpc.Agents.CodingAgent.ask_sync(pid, prompt, timeout: 60_000) do
      {:ok, result} ->
        Mix.shell().info("[smoke] result: #{inspect(result, pretty: true, limit: 20)}")
        evaluate(result, token, scratch_path)

      {:error, reason} ->
        Mix.shell().error("[smoke] ask_sync failed: #{inspect(reason)}")
        File.rm(scratch_path)
        exit({:shutdown, 1})
    end
  end

  defp evaluate(result, token, scratch_path) do
    text = result_to_text(result)
    File.rm(scratch_path)

    cond do
      String.contains?(text, token) ->
        Mix.shell().info("[smoke] ✓ agent reported the secret token (#{token})")
        :ok

      true ->
        Mix.shell().error(
          "[smoke] ✗ agent reply did not contain the expected token #{token}.\n" <>
            "Reply text:\n#{text}"
        )

        exit({:shutdown, 1})
    end
  end

  defp result_to_text(result) when is_binary(result), do: result
  defp result_to_text(%{response: r}) when is_binary(r), do: r
  defp result_to_text(%{result: r}) when is_binary(r), do: r
  defp result_to_text(%{content: c}) when is_binary(c), do: c
  defp result_to_text(other), do: inspect(other, limit: :infinity)

  defp create_scratch_file do
    home = System.get_env("HOME") || "/tmp"
    dir = Path.join([home, ".cache", "jido_hpc"])
    File.mkdir_p!(dir)

    token = "smoke-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
    path = Path.join(dir, "smoke_#{:erlang.unique_integer([:positive])}.txt")
    File.write!(path, "Secret token for the jido_hpc smoke test: #{token}\n")
    {path, token}
  end
end
