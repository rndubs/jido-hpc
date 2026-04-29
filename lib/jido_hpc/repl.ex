defmodule JidoHpc.REPL do
  @moduledoc """
  Interactive REPL for the `JidoHpc.Agents.CodingAgent`.

  Reads a prompt from stdin, streams the agent's reasoning to stdout
  with tool calls rendered inline, and prompts the human for approval
  whenever a `slurm_submit` returns under `:confirm_on_submit`
  autonomy.

  ## Loop

      jido-hpc> render a 4-GPU train job for ./run_train.py and submit it
      [thinking] …
      → tool: slurm_submit
        autonomy: :confirm_on_submit
        plan-first: rendered script written to /scratch/.../sbatch/foo-1.sh
        ─── #!/bin/bash ─────────────────────────────────────────────
        #SBATCH --job-name=foo
        ...
        ─────────────────────────────────────────────────────────────
        approve and submit? [y/N]: y
      ← tool result: %{submitted: true, job_id: "12345"}
      [assistant] Submitted as 12345. I'll watch it…

      jido-hpc> ^D

  ## Wiring

  The REPL talks to the agent through three injectable callbacks (the
  `t:io/0` struct), which makes the loop testable without a live LLM
  or stdin/stdout:

    * `read_line` — get the next user prompt
    * `write` — emit text to the user
    * `confirm` — yes/no prompt for plan-first approval

  Tests provide pre-canned versions; the production entry point wires
  them up to `IO.gets/1` and `IO.write/1`.

  ## Streaming events

  Streamed events come from `Jido.AI.Agent.ask_stream/3`. Known event
  kinds: `:assistant_token`, `:tool_call`, `:tool_result`,
  `:request_completed`. Unknown kinds are inspected verbatim — better
  to surface an unknown event than to drop it silently.
  """

  alias JidoHpc.AuditLog

  @type io :: %{
          read_line: (String.t() -> String.t() | :eof),
          write: (iodata() -> any()),
          confirm: (String.t() -> boolean())
        }

  @type opts :: [
          agent: module(),
          io: io(),
          session_id: String.t(),
          autonomy: :confirm_on_submit | :autonomous,
          dispatcher: module()
        ]

  @prompt "jido-hpc> "

  @doc """
  Run the REPL until the user closes stdin (Ctrl-D) or types `exit`.
  Returns `:ok` after a clean shutdown.
  """
  @spec run(opts()) :: :ok
  def run(opts \\ []) do
    state = init_state(opts)
    state.io.write.("jido-hpc REPL — session #{state.session_id}\n")
    loop(state)
  end

  # ---- Loop -------------------------------------------------------------

  defp loop(state) do
    case state.io.read_line.(@prompt) do
      :eof ->
        state.io.write.("\nbye.\n")
        :ok

      line when is_binary(line) ->
        case String.trim(line) do
          "" -> loop(state)
          "exit" -> :ok
          "quit" -> :ok
          prompt -> handle_prompt(state, prompt) |> loop()
        end
    end
  end

  defp handle_prompt(state, prompt) do
    prompt_hash = AuditLog.hash_prompt(prompt)

    ctx = %{
      session_id: state.session_id,
      prompt_hash: prompt_hash,
      autonomy: state.autonomy
    }

    case state.dispatcher.ask_stream(state.agent, prompt, ctx: ctx) do
      {:ok, %{request: request, events: events}} ->
        Enum.each(events, &render_event(state, &1))

        case state.dispatcher.await(state.agent, request) do
          {:ok, _result} -> :ok
          {:error, reason} -> state.io.write.("[error] #{inspect(reason)}\n")
        end

        state

      {:error, reason} ->
        state.io.write.("[error] dispatcher: #{inspect(reason)}\n")
        state
    end
  end

  # ---- Event rendering --------------------------------------------------

  @doc false
  def render_event(state, event)

  def render_event(state, %{kind: :assistant_token, data: %{token: tok}}) do
    state.io.write.(tok)
  end

  def render_event(state, %{kind: :tool_call, data: %{name: name, args: args}}) do
    state.io.write.([
      "\n→ tool: ",
      to_string(name),
      "\n  args: ",
      inspect(args, pretty: true, limit: 12),
      "\n"
    ])
  end

  def render_event(state, %{kind: :tool_result, data: %{name: name, result: result}}) do
    state.io.write.([
      "← tool result (",
      to_string(name),
      "): ",
      inspect(result, pretty: true, limit: 12),
      "\n"
    ])

    maybe_plan_first_prompt(state, name, result)
  end

  def render_event(state, %{kind: :request_completed}) do
    state.io.write.("\n")
  end

  def render_event(state, other) do
    state.io.write.(["[event] ", inspect(other, limit: 8), "\n"])
  end

  # ---- Plan-first approval ---------------------------------------------

  # When slurm_submit returns submitted: false because autonomy is
  # :confirm_on_submit, render the script and ask the user to approve.
  # Approval re-runs the action with confirm: true.
  defp maybe_plan_first_prompt(
         state,
         name,
         %{submitted: false, reason: :awaiting_confirmation, script: script, script_path: path} =
           result
       )
       when name in ["slurm_submit", :slurm_submit] do
    state.io.write.([
      "\n[plan-first] script written to ",
      path,
      "\n",
      banner("script"),
      script,
      banner(""),
      "\n"
    ])

    if state.io.confirm.("approve and submit? [y/N]: ") do
      params = Map.merge(submit_params(result), %{confirm: true})

      case state.dispatcher.run_action(JidoHpc.Actions.Slurm.Submit, params, %{}) do
        {:ok, %{job_id: id}} ->
          state.io.write.(["[approved] submitted as ", to_string(id), "\n"])

        {:error, reason} ->
          state.io.write.(["[approve-error] ", inspect(reason), "\n"])
      end
    else
      state.io.write.("[skipped]\n")
    end
  end

  defp maybe_plan_first_prompt(_state, _name, _result), do: :ok

  defp submit_params(%{spec: spec}) do
    Map.from_struct(spec)
  end

  defp banner(label) do
    line = String.duplicate("─", 60)
    "\n" <> line <> if(label == "", do: "\n", else: " " <> label <> " " <> line <> "\n")
  end

  # ---- Setup ------------------------------------------------------------

  defp init_state(opts) do
    %{
      agent: Keyword.get(opts, :agent, JidoHpc.Agents.CodingAgent),
      io: Keyword.get(opts, :io, default_io()),
      session_id: Keyword.get(opts, :session_id, AuditLog.new_session_id()),
      autonomy:
        Keyword.get(
          opts,
          :autonomy,
          Application.get_env(:jido_hpc, :autonomy, :confirm_on_submit)
        ),
      dispatcher: Keyword.get(opts, :dispatcher, JidoHpc.REPL.Dispatcher.Live)
    }
  end

  defp default_io do
    %{
      read_line: fn prompt ->
        case IO.gets(prompt) do
          :eof -> :eof
          {:error, _} -> :eof
          data when is_binary(data) -> data
        end
      end,
      write: &IO.write/1,
      confirm: fn prompt ->
        case IO.gets(prompt) do
          data when is_binary(data) ->
            data |> String.trim() |> String.downcase() |> Kernel.in(["y", "yes"])

          _ ->
            false
        end
      end
    }
  end
end
