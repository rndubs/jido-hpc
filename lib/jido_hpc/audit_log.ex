defmodule JidoHpc.AuditLog do
  @moduledoc """
  Structured audit log for Slurm submissions and other state-changing
  agent actions.

  Each entry is a single line of JSON written to an append-only file.
  One line = one event, so an operator can `tail -f`, `jq` over it, or
  ship it to a SIEM without any custom parser.

  ## Why JSON-lines on disk

  An HPC login node is shared infrastructure. We want a tamper-evident,
  structured trail of every `sbatch` the agent issued (autonomous or
  otherwise) without a database dependency. JSON-lines under
  `~/.config/jido_hpc/audit.log` (or `JIDO_HPC_AUDIT_LOG`) is simple,
  greppable, and easy to rotate.

  ## Schema

  The plan's required fields per submission:

      %{
        ts: iso8601_string,         # event time, microsecond UTC
        session_id: String.t,       # opaque per-REPL or per-API session
        prompt_hash: String.t,      # SHA-256 hex of the prompt that
                                    # produced this submission (so we
                                    # can correlate without storing the
                                    # prompt itself, which may contain
                                    # PII / proprietary code)
        job_id: String.t | nil,     # nil if autonomy=:confirm_on_submit
        sbatch_path: String.t,      # path to the rendered script
        autonomy: atom,             # :confirm_on_submit | :autonomous
        submitted: boolean,
        event: atom                 # :slurm_submit (extensible)
      }

  Additional keys are accepted and merged in.

  ## File location

  Resolved in this order:

    1. `Application.get_env(:jido_hpc, :audit_log_path)`
    2. `JIDO_HPC_AUDIT_LOG` environment variable
    3. `$XDG_CONFIG_HOME/jido_hpc/audit.log`
    4. `~/.config/jido_hpc/audit.log`

  The directory is created on first write with mode 0700; the log file
  is chmod 0600. Secrets must never reach this file — that's the
  caller's responsibility (see `prompt_hash` above).

  ## Concurrency

  Writes use `File.open!/3` with `[:append, :raw, :delayed_write]` plus
  a tiny `:global` lock so concurrent agents on the same login node
  don't interleave half-lines. For the expected submission rate (jobs,
  not log spam) this is fine.
  """

  require Logger

  @env_key "JIDO_HPC_AUDIT_LOG"
  @lock_name {__MODULE__, :write_lock}

  @type entry :: %{
          required(:event) => atom(),
          optional(atom()) => any()
        }

  @doc """
  Append `entry` to the audit log. Returns `{:ok, path}` or
  `{:error, reason}`. Failure to write is logged at warning level but
  does not raise — losing an audit line shouldn't crash a job
  submission.
  """
  @spec append(entry()) :: {:ok, Path.t()} | :disabled | {:error, term()}
  def append(entry) when is_map(entry) do
    case resolve_path() do
      :disabled ->
        :disabled

      _path ->
        with {:ok, path} <- ensure_log_path(),
             {:ok, line} <- encode(timestamp(entry)),
             :ok <- write_line(path, line) do
          {:ok, path}
        else
          {:error, reason} = err ->
            Logger.warning("AuditLog append failed: #{inspect(reason)}")
            err
        end
    end
  end

  @doc "Convenience: hash a prompt to a hex SHA-256 digest."
  @spec hash_prompt(binary()) :: String.t()
  def hash_prompt(prompt) when is_binary(prompt) do
    :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
  end

  @doc "Generate a new opaque session id."
  @spec new_session_id() :: String.t()
  def new_session_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  @doc "Resolve the audit log path without writing to it."
  @spec path() :: {:ok, Path.t()} | :disabled | {:error, term()}
  def path do
    case resolve_path() do
      :disabled -> :disabled
      _ -> ensure_log_path()
    end
  end

  # ---- internals --------------------------------------------------------

  defp ensure_log_path do
    path = resolve_path()
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir) do
      # Best-effort dir chmod — fails silently on shared dirs we don't
      # own (e.g. /tmp). The file itself is chmod'd 0600 in
      # ensure_chmod/1, which is the actual data protection.
      _ = File.chmod(dir, 0o700)
      {:ok, path}
    end
  end

  defp resolve_path do
    case Application.get_env(:jido_hpc, :audit_log_path) do
      :disabled ->
        :disabled

      nil ->
        cond do
          env = System.get_env(@env_key) ->
            env

          xdg = System.get_env("XDG_CONFIG_HOME") ->
            Path.join([xdg, "jido_hpc", "audit.log"])

          home = System.get_env("HOME") ->
            Path.join([home, ".config", "jido_hpc", "audit.log"])

          true ->
            Path.join([System.tmp_dir!(), "jido_hpc-audit.log"])
        end

      configured when is_binary(configured) ->
        configured
    end
  end

  defp timestamp(entry) do
    Map.put_new_lazy(entry, :ts, fn ->
      DateTime.utc_now() |> DateTime.to_iso8601()
    end)
  end

  defp encode(entry) do
    {:ok, Jason.encode!(entry) <> "\n"}
  rescue
    e -> {:error, {:encode_failed, Exception.message(e)}}
  end

  # Cross-pid mutex. The lock id MUST NOT include `self()` — `:global`
  # locks are re-entrant on the same id, so a unique-per-pid id would
  # mean every caller acquires immediately and the "lock" is a no-op.
  defp write_line(path, line) do
    :global.set_lock(@lock_name, [node()])

    try do
      ensure_chmod(path)

      with {:ok, fd} <- File.open(path, [:append, :raw]),
           :ok <- :file.write(fd, line),
           :ok <- File.close(fd) do
        :ok
      end
    after
      :global.del_lock(@lock_name, [node()])
    end
  end

  # Touch the file with mode 0600 if missing, so audit data is never
  # written to a world-readable file even briefly. If the file already
  # exists with the right mode this is a cheap no-op.
  defp ensure_chmod(path) do
    case File.exists?(path) do
      true ->
        :ok

      false ->
        with :ok <- File.touch(path),
             :ok <- File.chmod(path, 0o600) do
          :ok
        end
    end
  end
end
