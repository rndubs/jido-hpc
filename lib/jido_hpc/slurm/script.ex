defmodule JidoHpc.Slurm.Script do
  @moduledoc """
  Render a `JidoHpc.Slurm.JobSpec` into a deterministic sbatch script.

  ## Why a renderer

  The LLM is forbidden from emitting raw `#SBATCH` directives — it fills a
  typed `JobSpec` instead. This module is the only sanctioned producer of
  sbatch script text. Everything that lands in the script comes from a
  validated field.

  ## Output shape

      #!/bin/bash
      #SBATCH --job-name=<name>
      #SBATCH --time=<time>
      #SBATCH --nodes=<N>
      ...
      set -euo pipefail
      module load <m1>
      module load <m2>
      export FOO="bar"
      cd "<workdir>"
      "<command[0]>" "<command[1]>" ...

  Argument vectors and env values are bash-quoted so a value containing a
  space or shell-meta cannot break out of its slot. We refuse to render
  values that contain a literal NUL or non-printable control character —
  those would corrupt the script regardless of quoting.

  ## Secrets

  By design, the renderer never reads ambient environment variables.
  Anything sensitive must come from disk on the compute node (typically
  sourced from `~/.config/jido_hpc`). See `plan.md` "Secrets never enter
  sbatch scripts."
  """

  alias JidoHpc.Slurm.JobSpec

  @doc """
  Render a `JobSpec` to an iolist or binary sbatch script.

  Returns `{:ok, script}` or `{:error, reason}`. Most validation already
  happened in `JobSpec.new/1`; this layer only catches things specific to
  rendering (unprintable bytes, NULs).
  """
  @spec render(JobSpec.t()) :: {:ok, String.t()} | {:error, term()}
  def render(%JobSpec{} = spec) do
    with :ok <- check_renderable(spec) do
      script = [
        "#!/bin/bash\n",
        directives(spec),
        "\n",
        "set -euo pipefail\n",
        modules(spec),
        env_exports(spec),
        cd_line(spec),
        command_line(spec)
      ]

      {:ok, IO.iodata_to_binary(script)}
    end
  end

  @doc "Bang variant of `render/1`."
  @spec render!(JobSpec.t()) :: String.t()
  def render!(spec) do
    case render(spec) do
      {:ok, s} -> s
      {:error, r} -> raise ArgumentError, "render failed: #{inspect(r)}"
    end
  end

  # --- directives ---------------------------------------------------------

  defp directives(spec) do
    [
      directive("job-name", spec.name),
      directive("time", spec.time),
      directive("nodes", Integer.to_string(spec.nodes)),
      directive("ntasks", Integer.to_string(spec.ntasks)),
      directive("cpus-per-task", Integer.to_string(spec.cpus_per_task)),
      maybe_directive("mem", spec.mem),
      maybe_directive("partition", spec.partition),
      maybe_directive("account", spec.account),
      maybe_directive("qos", spec.qos),
      maybe_directive("array", spec.array),
      maybe_directive("dependency", spec.dependency),
      gres_gpu(spec.gpus),
      directive("chdir", spec.workdir),
      directive("output", spec.output),
      directive("error", spec.error)
    ]
  end

  defp directive(key, value), do: ["#SBATCH --", key, "=", value, "\n"]

  defp maybe_directive(_key, nil), do: []
  defp maybe_directive(key, value), do: directive(key, value)

  defp gres_gpu(nil), do: []
  defp gres_gpu(0), do: []
  defp gres_gpu(n) when is_integer(n) and n > 0, do: directive("gres", "gpu:#{n}")

  # --- body ---------------------------------------------------------------

  defp modules(%JobSpec{modules: []}), do: []

  defp modules(%JobSpec{modules: mods}) do
    Enum.map(mods, fn m -> ["module load ", m, "\n"] end)
  end

  defp env_exports(%JobSpec{env: env}) when map_size(env) == 0, do: []

  defp env_exports(%JobSpec{env: env}) do
    env
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> ["export ", k, "=", bash_quote(v), "\n"] end)
  end

  defp cd_line(%JobSpec{workdir: wd}), do: ["cd ", bash_quote(wd), "\n"]

  defp command_line(%JobSpec{command: argv}) do
    [Enum.map_join(argv, " ", &bash_quote/1), "\n"]
  end

  # --- safety -------------------------------------------------------------

  defp check_renderable(%JobSpec{} = spec) do
    candidates =
      [
        spec.name,
        spec.time,
        spec.workdir,
        spec.output,
        spec.error,
        spec.partition,
        spec.account,
        spec.qos,
        spec.array,
        spec.dependency,
        spec.mem
      ] ++
        spec.command ++
        Map.keys(spec.env) ++
        Map.values(spec.env) ++
        spec.modules

    Enum.reduce_while(candidates, :ok, fn
      nil, acc ->
        {:cont, acc}

      v, acc when is_binary(v) ->
        if printable?(v),
          do: {:cont, acc},
          else: {:halt, {:error, {:unrenderable, v}}}

      v, _acc ->
        {:halt, {:error, {:unrenderable, v}}}
    end)
  end

  # POSIX-printable: any byte we let through must be either a space, tab, or
  # in the printable ASCII range (0x20-0x7E), OR be a UTF-8 continuation
  # byte (>= 0x80) belonging to a valid UTF-8 string. We reject NUL, BEL,
  # newline, CR — anything that could break script structure.
  defp printable?(s) when is_binary(s) do
    String.valid?(s) and not Regex.match?(~r/[\x00-\x08\x0A-\x1F\x7F]/, s)
  end

  # Single-quote bash quoting: replace `'` with `'\''`, wrap in `'`. This
  # is the only safe form — double quotes still expand `$`, backticks, etc.
  defp bash_quote(s) when is_binary(s) do
    escaped = String.replace(s, "'", "'\\''")
    [?', escaped, ?']
  end
end
