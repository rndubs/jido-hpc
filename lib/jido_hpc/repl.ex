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

  Before entering the loop, runs `JidoHpc.Config.api_key_status/0` and
  exits cleanly with an actionable message if no API key is configured
  for the default LLM provider. Pass `skip_api_key_check: true` to
  bypass the preflight (used by tests with a stub dispatcher).
  """
  @spec run(opts()) :: :ok
  def run(opts \\ []) do
    state = init_state(opts)

    cond do
      Keyword.get(opts, :skip_api_key_check, false) ->
        start_loop(state)

      true ->
        case JidoHpc.Config.api_key_status() do
          {:ok, %{provider: provider, source: source}} ->
            state.io.write.("[ok] LLM provider #{provider} key loaded from #{source}\n")
            start_loop(state)

          {:error, msg} ->
            state.io.write.(msg)
            :ok
        end
    end
  end

  defp start_loop(state) do
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
    # Stash the hash so the plan-first re-submit (which fires from
    # render_event/2 well after we leave this function) can attach
    # the same correlation tag to its audit entry.
    state = %{state | last_prompt_hash: prompt_hash}

    ctx = %{
      session_id: state.session_id,
      prompt_hash: prompt_hash,
      autonomy: state.autonomy
    }

    # Pass via `tool_context:` so jido_ai merges this into every action's
    # `ctx` for the duration of the request. `Slurm.Submit` reads
    # `ctx.autonomy` first; `AuditLog` reads `:session_id` / `:prompt_hash`.
    case state.dispatcher.ask_stream(state.agent, prompt, tool_context: ctx) do
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
      # Carry the session_id and prompt_hash through the second
      # invocation so the audit log can correlate the two entries.
      # The original session_id was attached to the result by
      # `Slurm.Submit` (see `run/2`); fall back to the REPL's session
      # if it's missing.
      session_id = Map.get(result, :session_id) || state.session_id
      ctx = %{session_id: session_id, prompt_hash: state.last_prompt_hash}

      params =
        result
        |> submit_params()
        |> Map.merge(%{confirm: true, session_id: session_id})

      case state.dispatcher.run_action(JidoHpc.Actions.Slurm.Submit, params, ctx) do
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

  @banner_width 60
  @banner_line String.duplicate("─", @banner_width)

  # Both banner lines have the same on-screen width so the rendered
  # script lines up with its bookends.
  defp banner(""), do: "\n" <> @banner_line <> "\n"

  defp banner(label) do
    prefix = "── " <> label <> " "
    fill_len = max(@banner_width - String.length(prefix), 0)
    "\n" <> prefix <> String.duplicate("─", fill_len) <> "\n"
  end

  # ---- Setup ------------------------------------------------------------

  defp init_state(opts) do
    %{
      agent: Keyword.get(opts, :agent, JidoHpc.Agents.CodingAgent),
      io: Keyword.get(opts, :io, default_io()),
      session_id: Keyword.get(opts, :session_id, AuditLog.new_session_id()),
      last_prompt_hash: nil,
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
