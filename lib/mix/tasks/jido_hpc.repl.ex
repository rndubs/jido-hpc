defmodule Mix.Tasks.JidoHpc.Repl do
  @shortdoc "Run an interactive REPL against the jido_hpc CodingAgent"

  @moduledoc """
  Start the application and drop into `JidoHpc.REPL.run/1`.

      mix jido_hpc.repl
      mix jido_hpc.repl --autonomous
      mix jido_hpc.repl --session my-session-id

  Flags:

    * `--autonomous` — submit Slurm jobs without per-submission
      approval. Every submission is still audit-logged.
    * `--session <id>` — pin a session id (default: random).
    * `--agent <module>` — override the agent module
      (default `JidoHpc.Agents.CodingAgent`).

  See `JidoHpc.REPL` for the interaction model.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          autonomous: :boolean,
          session: :string,
          agent: :string
        ]
      )

    Mix.Task.run("app.start")

    repl_opts =
      []
      |> maybe_put(:autonomy, if(opts[:autonomous], do: :autonomous, else: nil))
      |> maybe_put(:session_id, opts[:session])
      |> maybe_put(:agent, resolve_agent(opts[:agent]))

    JidoHpc.REPL.run(repl_opts)
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  # Look up an already-loaded module by name. Refuses to atomize
  # arbitrary CLI input (avoids atom-table DoS) and refuses unknown
  # modules with a clear Mix error rather than a silent fallthrough
  # to "function_exported? = false".
  defp resolve_agent(nil), do: nil

  defp resolve_agent(name) when is_binary(name) do
    full = if String.starts_with?(name, "Elixir."), do: name, else: "Elixir." <> name

    try do
      mod = String.to_existing_atom(full)

      case Code.ensure_loaded(mod) do
        {:module, ^mod} -> mod
        _ -> Mix.raise("Unknown agent module: #{name}")
      end
    rescue
      ArgumentError -> Mix.raise("Unknown agent module: #{name}")
    end
  end
end
