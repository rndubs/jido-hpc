defmodule JidoHpc.Actions.Slurm.Submit do
  @moduledoc """
  Submit a Slurm job from a `JidoHpc.Slurm.JobSpec`-shaped payload.

  Behaviour depends on the agent's `:autonomy` setting (read from
  `Application.get_env(:jido_hpc, :autonomy)` or the optional
  `autonomy:` parameter):

    * `:confirm_on_submit` (default) — render the script, write it to disk,
      and return `%{submitted: false, ...}`. The caller (or human) is
      expected to invoke `Slurm.Submit` again with `confirm: true` (or
      switch to `:autonomous`) to actually run.

    * `:autonomous` — render, write, and `sbatch` immediately. The result
      includes the `job_id`.

  The script is always written to `<workdir>/.jido_hpc/sbatch/<name>-<rand>.sh`
  with mode 0700 so it stays auditable.
  """

  use Jido.Action,
    name: "slurm_submit",
    description:
      "Submit a Slurm job. Renders an sbatch script from a typed JobSpec, writes it under " <>
        "<workdir>/.jido_hpc/sbatch/, and (depending on autonomy) calls sbatch.",
    schema: [
      name: [type: :string, required: true],
      time: [type: :string, required: true],
      workdir: [type: :string, required: true],
      command: [type: {:list, :string}, required: true],
      nodes: [type: :pos_integer, default: 1],
      ntasks: [type: :pos_integer, default: 1],
      cpus_per_task: [type: :pos_integer, default: 1],
      mem: [type: {:or, [:string, nil]}, default: nil],
      gpus: [type: {:or, [:non_neg_integer, nil]}, default: nil],
      partition: [type: {:or, [:string, nil]}, default: nil],
      modules: [type: {:list, :string}, default: []],
      env: [type: :map, default: %{}],
      array: [type: {:or, [:string, nil]}, default: nil],
      dependency: [type: {:or, [:string, nil]}, default: nil],
      output: [type: {:or, [:string, nil]}, default: nil],
      error: [type: {:or, [:string, nil]}, default: nil],
      account: [type: {:or, [:string, nil]}, default: nil],
      qos: [type: {:or, [:string, nil]}, default: nil],
      confirm: [
        type: :boolean,
        default: false,
        doc: "Set true to override `:confirm_on_submit` autonomy and submit anyway."
      ],
      autonomy: [
        type: {:or, [:atom, nil]},
        default: nil,
        doc: "Override the default autonomy. One of :confirm_on_submit | :autonomous."
      ],
      session_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Opaque per-session id for the audit log. Generated if absent."
      ],
      prompt_hash: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "SHA-256 hex of the prompt that produced this submission. " <>
            "Stored in the audit log so an operator can correlate without " <>
            "logging the prompt itself."
      ]
    ]

  alias JidoHpc.Actions.Slurm.TemplateScript
  alias JidoHpc.AuditLog
  alias JidoHpc.Slurm.CLI

  @impl true
  def run(params, ctx) do
    # session_id / prompt_hash are session-scoped and so are most
    # naturally passed via `ctx` (the agent's run context). Fall back
    # to the action params for callers that don't have a ctx surface
    # (e.g. the REPL's plan-first re-submit), and finally to a fresh
    # session id so an audit row is always self-describing.
    session_id =
      Map.get(params, :session_id) ||
        Map.get(ctx, :session_id) ||
        AuditLog.new_session_id()

    prompt_hash =
      Map.get(params, :prompt_hash) || Map.get(ctx, :prompt_hash)

    template_params = Map.drop(params, [:confirm, :autonomy, :session_id, :prompt_hash])
    autonomy = effective_autonomy(params)

    with {:ok, %{spec: spec, script: script, workdir: workdir}} <-
           TemplateScript.run(template_params, ctx),
         {:ok, script_path} <- write_script(workdir, spec.name, script) do
      result = do_submit(script_path, spec, autonomy, params.confirm)

      audit(session_id, prompt_hash, autonomy, script_path, result)

      case result do
        {:ok, ok_map} ->
          {:ok,
           Map.merge(ok_map, %{
             spec: spec,
             script: script,
             script_path: script_path,
             autonomy: autonomy,
             session_id: session_id
           })}

        {:error, _} = err ->
          err
      end
    end
  end

  defp effective_autonomy(%{autonomy: a}) when a in [:confirm_on_submit, :autonomous], do: a

  defp effective_autonomy(_) do
    Application.get_env(:jido_hpc, :autonomy, :confirm_on_submit)
  end

  defp do_submit(_path, _spec, :confirm_on_submit, false) do
    {:ok, %{submitted: false, job_id: nil, reason: :awaiting_confirmation}}
  end

  defp do_submit(path, spec, _autonomy, _confirm) do
    case CLI.sbatch(path, spec) do
      {:ok, %{job_id: id, stdout: out}} ->
        {:ok, %{submitted: true, job_id: id, sbatch_stdout: out}}

      {:error, reason} ->
        {:error, {:sbatch_failed, reason}}
    end
  end

  defp audit(session_id, prompt_hash, autonomy, script_path, result) do
    {submitted, job_id, error} =
      case result do
        {:ok, %{submitted: s, job_id: id}} -> {s, id, nil}
        {:ok, %{submitted: s}} -> {s, nil, nil}
        {:error, reason} -> {false, nil, inspect(reason)}
      end

    AuditLog.append(%{
      event: :slurm_submit,
      session_id: session_id,
      prompt_hash: prompt_hash,
      job_id: job_id,
      sbatch_path: script_path,
      autonomy: autonomy,
      submitted: submitted,
      error: error
    })
  end

  defp write_script(workdir, name, body) do
    dir = Path.join([workdir, ".jido_hpc", "sbatch"])

    with :ok <- File.mkdir_p(dir) do
      _ = File.chmod(dir, 0o700)
      filename = "#{name}-#{:erlang.unique_integer([:positive])}.sh"
      path = Path.join(dir, filename)

      with :ok <- File.write(path, body),
           :ok <- File.chmod(path, 0o700) do
        {:ok, path}
      end
    end
  end
end
