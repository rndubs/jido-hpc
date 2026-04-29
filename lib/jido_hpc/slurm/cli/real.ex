defmodule JidoHpc.Slurm.CLI.Real do
  @moduledoc """
  Default `JidoHpc.Slurm.CLI` implementation: shells out to the real
  Slurm CLI tools via `System.cmd/3`, gated by `Safety.CmdGuard` and the
  `RateLimiter`.

  Each parser tries `--json` first. If that fails (older Slurm without
  `--json`, or output the parser doesn't understand), it falls back to
  `--parsable2 --format=…` and parses the `|`-delimited rows. Default
  human-readable output is never scraped.
  """

  @behaviour JidoHpc.Slurm.CLI

  alias JidoHpc.Safety.{CmdGuard, RateLimiter}

  # ---- sbatch -----------------------------------------------------------

  @impl true
  def sbatch(script_path, _spec) when is_binary(script_path) do
    with {:ok, {cmd, args}} <- CmdGuard.validate("sbatch", ["--parsable", script_path]),
         {:ok, {out, 0}} <- run(cmd, args) do
      case parse_sbatch(out) do
        {:ok, job_id} -> {:ok, %{job_id: job_id, stdout: out}}
        :error -> {:error, {:sbatch_unparseable, out}}
      end
    else
      {:ok, {out, status}} -> {:error, {:sbatch_failed, status, out}}
      err -> err
    end
  end

  # `sbatch --parsable` prints just the JobID (or `JobID;cluster`).
  defp parse_sbatch(out) do
    out
    |> String.trim()
    |> String.split(";", parts: 2)
    |> hd()
    |> case do
      "" -> :error
      id ->
        if Regex.match?(~r/^\d+(_\d+)?$/, id), do: {:ok, id}, else: :error
    end
  end

  # ---- squeue -----------------------------------------------------------

  @impl true
  def squeue(opts) do
    extra = filter_opts_to_args(opts, [:user, :job, :partition])

    case json_run("squeue", ["--json"] ++ extra) do
      {:ok, %{} = json} -> {:ok, parse_squeue_json(json)}
      {:error, _} -> squeue_parsable(extra)
    end
  end

  defp squeue_parsable(extra) do
    fmt = "JobID|JobName|State|Reason|Partition|TimeUsed|TimeLimit|NodeList"

    case run_validated("squeue", ["--parsable2", "--noheader", "--format=#{fmt}"] ++ extra) do
      {:ok, out} ->
        rows =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_squeue_row/1)

        {:ok, rows}

      err ->
        err
    end
  end

  defp parse_squeue_row(line) do
    [job_id, name, state, reason, partition, elapsed, time_limit, nodes] =
      pad(String.split(line, "|"), 8)

    %{
      job_id: job_id,
      name: name,
      state: state,
      reason: reason,
      partition: partition,
      elapsed: elapsed,
      time_limit: time_limit,
      nodes: nodes
    }
  end

  defp parse_squeue_json(%{"jobs" => jobs}) when is_list(jobs) do
    Enum.map(jobs, &normalize_squeue_job/1)
  end

  defp parse_squeue_json(_), do: []

  defp normalize_squeue_job(job) when is_map(job) do
    %{
      job_id: to_string(job["job_id"] || job["jobid"] || ""),
      name: job["name"] || job["job_name"],
      state: extract_state(job["job_state"] || job["state"]),
      reason: job["state_reason"] || job["reason"],
      partition: job["partition"],
      nodes: job["nodes"]
    }
  end

  # `job_state` is either a string ("PENDING") or a list (["PENDING"]).
  defp extract_state(state) when is_binary(state), do: state
  defp extract_state([first | _]) when is_binary(first), do: first
  defp extract_state(_), do: nil

  # ---- sacct ------------------------------------------------------------

  @impl true
  def sacct(job_id, opts) when is_binary(job_id) do
    case json_run("sacct", ["--json", "-j", job_id]) do
      {:ok, %{} = json} -> {:ok, parse_sacct_json(json)}
      {:error, _} -> sacct_parsable(job_id, opts)
    end
  end

  defp sacct_parsable(job_id, _opts) do
    fmt = "JobID,State,ExitCode,DerivedExitCode,MaxRSS,Elapsed,ReqMem,Reason"

    case run_validated("sacct", [
           "--parsable2",
           "--noheader",
           "--format=#{fmt}",
           "-j",
           job_id
         ]) do
      {:ok, out} ->
        rows =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_sacct_row/1)

        {:ok, rows}

      err ->
        err
    end
  end

  defp parse_sacct_row(line) do
    [job_id, state, exit_code, derived, max_rss, elapsed, req_mem, reason] =
      pad(String.split(line, "|"), 8)

    %{
      job_id: job_id,
      state: state,
      exit_code: parse_exit_code(exit_code),
      derived_exit_code: parse_exit_code(derived),
      max_rss: max_rss,
      elapsed: elapsed,
      req_mem: req_mem,
      reason: reason
    }
  end

  # "0:0" -> 0, "1:0" -> 1, anything weird -> nil
  defp parse_exit_code(""), do: nil
  defp parse_exit_code(nil), do: nil

  defp parse_exit_code(s) when is_binary(s) do
    s
    |> String.split(":", parts: 2)
    |> hd()
    |> Integer.parse()
    |> case do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_sacct_json(%{"jobs" => jobs}) when is_list(jobs) do
    Enum.map(jobs, &normalize_sacct_job/1)
  end

  defp parse_sacct_json(_), do: []

  defp normalize_sacct_job(job) do
    state =
      case job["state"] do
        %{"current" => c} when is_binary(c) -> c
        %{"current" => [c | _]} when is_binary(c) -> c
        s when is_binary(s) -> s
        _ -> nil
      end

    exit_code =
      case job["exit_code"] do
        %{"return_code" => %{"number" => n}} -> n
        %{"return_code" => n} when is_integer(n) -> n
        _ -> nil
      end

    %{
      job_id: to_string(job["job_id"] || ""),
      state: state,
      exit_code: exit_code,
      elapsed: job["time"] && job["time"]["elapsed"]
    }
  end

  # ---- scancel ----------------------------------------------------------

  @impl true
  def scancel(job_id, _opts) when is_binary(job_id) do
    case run_validated("scancel", [job_id]) do
      {:ok, _out} -> :ok
      err -> err
    end
  end

  # ---- sinfo ------------------------------------------------------------

  @impl true
  def sinfo(opts) do
    case json_run("sinfo", ["--json"]) do
      {:ok, %{} = json} -> {:ok, parse_sinfo_json(json)}
      {:error, _} -> sinfo_parsable(opts)
    end
  end

  defp sinfo_parsable(_opts) do
    fmt = "Partition|Avail|Nodes|StateLong|CPUs|Memory"

    case run_validated("sinfo", ["--parsable2", "--noheader", "--format=#{fmt}"]) do
      {:ok, out} ->
        rows =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_sinfo_row/1)

        {:ok, rows}

      err ->
        err
    end
  end

  defp parse_sinfo_row(line) do
    [partition, avail, nodes, state, cpus, memory] = pad(String.split(line, "|"), 6)

    %{
      partition: partition,
      avail: avail,
      nodes: nodes,
      state: state,
      cpus: cpus,
      memory: memory
    }
  end

  defp parse_sinfo_json(%{"sinfo" => entries}) when is_list(entries) do
    Enum.map(entries, fn e ->
      %{
        partition: e["partition"] && e["partition"]["name"],
        avail: e["partition"] && e["partition"]["state"],
        nodes: e["nodes"] && e["nodes"]["count"],
        state: extract_state(e["node"] && e["node"]["state"])
      }
    end)
  end

  defp parse_sinfo_json(_), do: []

  # ---- scontrol show job ------------------------------------------------

  @impl true
  def scontrol_show_job(job_id, _opts) when is_binary(job_id) do
    case json_run("scontrol", ["show", "job", job_id, "--json"]) do
      {:ok, %{} = json} ->
        case parse_squeue_json(json) do
          [first | _] -> {:ok, first}
          _ -> {:error, :not_found}
        end

      {:error, _} ->
        scontrol_kv(job_id)
    end
  end

  # `scontrol show job N` (no --json) emits `Key=Value Key=Value ...`
  defp scontrol_kv(job_id) do
    case run_validated("scontrol", ["show", "job", job_id]) do
      {:ok, out} ->
        kvs =
          out
          |> String.split(~r/\s+/, trim: true)
          |> Enum.flat_map(fn token ->
            case String.split(token, "=", parts: 2) do
              [k, v] -> [{normalize_key(k), v}]
              _ -> []
            end
          end)
          |> Map.new()

        {:ok, kvs}

      err ->
        err
    end
  end

  defp normalize_key(k) do
    k
    |> Macro.underscore()
    |> String.to_atom()
  end

  # ---- subprocess plumbing ---------------------------------------------

  defp run_validated(cmd, args, opts \\ []) do
    with {:ok, {c, a}} <- CmdGuard.validate(cmd, args),
         {:ok, {out, 0}} <- run(c, a, opts) do
      {:ok, out}
    else
      {:ok, {out, status}} -> {:error, {:nonzero_exit, status, out}}
      err -> err
    end
  end

  defp run(cmd, args, opts \\ []) do
    cmd_opts =
      case Keyword.get(opts, :merge_stderr, true) do
        true -> [stderr_to_stdout: true]
        false -> []
      end

    case RateLimiter.run(fn -> System.cmd(cmd, args, cmd_opts) end) do
      {:error, :rate_limited} = err -> err
      {output, status} -> {:ok, {output, status}}
    end
  end

  # JSON commands MUST NOT merge stderr — Slurm sometimes prints
  # warnings ("slurmctld: warning: ...") that would otherwise corrupt
  # the JSON document on stdout and cause Jason.decode to fail. Stderr
  # is dropped on the floor; if you want it for diagnostics, use the
  # --parsable2 path instead.
  defp json_run(cmd, args) do
    case run_validated(cmd, args, merge_stderr: false) do
      {:ok, out} -> decode_json(out)
      err -> err
    end
  end

  defp decode_json(out) do
    if Code.ensure_loaded?(Jason) do
      case Jason.decode(out) do
        {:ok, json} -> {:ok, json}
        {:error, reason} -> {:error, {:json_decode, reason}}
      end
    else
      {:error, :jason_unavailable}
    end
  end

  defp filter_opts_to_args(opts, allowed) do
    Enum.flat_map(opts, fn
      {k, v} when is_atom(k) ->
        if k in allowed and is_binary(v),
          do: ["--" <> Atom.to_string(k), v],
          else: []

      _ ->
        []
    end)
  end

  defp pad(list, n) when length(list) >= n, do: Enum.take(list, n)
  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))
end
