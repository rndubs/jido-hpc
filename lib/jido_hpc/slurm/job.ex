defmodule JidoHpc.Slurm.Job do
  @moduledoc """
  Runtime state of a Slurm job: id, last-known state, exit code, accounting
  metrics, and the original `JobSpec`.

  ## States

  Slurm exposes many state strings; we collapse them onto a small set:

      :pending     -> PENDING / CONFIGURING / REQUEUED / RESV_DEL_HOLD
      :running     -> RUNNING / COMPLETING / SIGNALING / STAGE_OUT
      :completed   -> COMPLETED
      :failed      -> FAILED / BOOT_FAIL / DEADLINE / SPECIAL_EXIT
      :timeout     -> TIMEOUT
      :oom         -> OUT_OF_MEMORY
      :cancelled   -> CANCELLED / CANCELLED+ (with sacct annotations)
      :node_fail   -> NODE_FAIL
      :preempted   -> PREEMPTED
      :unknown     -> anything we don't recognize

  Terminal states: `:completed`, `:failed`, `:timeout`, `:oom`, `:cancelled`,
  `:node_fail`, `:preempted`. Use `terminal?/1` to test.

  This module is a passive struct + transitions; sensor/actions own the IO.
  """

  alias JidoHpc.Slurm.JobSpec

  @type state ::
          :pending
          | :running
          | :completed
          | :failed
          | :timeout
          | :oom
          | :cancelled
          | :node_fail
          | :preempted
          | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          state: state(),
          raw_state: String.t() | nil,
          exit_code: non_neg_integer() | nil,
          derived_exit_code: non_neg_integer() | nil,
          reason: String.t() | nil,
          elapsed: String.t() | nil,
          max_rss: String.t() | nil,
          submitted_at: DateTime.t() | nil,
          updated_at: DateTime.t(),
          spec: JobSpec.t() | nil,
          script_path: String.t() | nil
        }

  @enforce_keys [:id, :state, :updated_at]
  defstruct [
    :id,
    :state,
    :raw_state,
    :exit_code,
    :derived_exit_code,
    :reason,
    :elapsed,
    :max_rss,
    :submitted_at,
    :updated_at,
    :spec,
    :script_path
  ]

  @doc "Build a fresh job record (state defaults to :pending)."
  @spec new(String.t(), keyword()) :: t()
  def new(id, opts \\ []) when is_binary(id) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: id,
      state: Keyword.get(opts, :state, :pending),
      raw_state: Keyword.get(opts, :raw_state),
      exit_code: Keyword.get(opts, :exit_code),
      derived_exit_code: Keyword.get(opts, :derived_exit_code),
      reason: Keyword.get(opts, :reason),
      elapsed: Keyword.get(opts, :elapsed),
      max_rss: Keyword.get(opts, :max_rss),
      submitted_at: Keyword.get(opts, :submitted_at, now),
      updated_at: now,
      spec: Keyword.get(opts, :spec),
      script_path: Keyword.get(opts, :script_path)
    }
  end

  @terminal ~w(completed failed timeout oom cancelled node_fail preempted)a

  @doc "True when the job is in a state that will not change again."
  @spec terminal?(t() | state()) :: boolean()
  def terminal?(%__MODULE__{state: s}), do: s in @terminal
  def terminal?(state) when is_atom(state), do: state in @terminal

  @doc "Map a Slurm state string to our internal atom."
  @spec parse_state(String.t() | nil) :: state()
  def parse_state(nil), do: :unknown

  def parse_state(s) when is_binary(s) do
    # Slurm state strings may carry annotations like "CANCELLED+",
    # "CANCELLED by 1234" (sacct), or "RUNNING (Reason)". Trim, upper,
    # then take the first token by either '+' or whitespace.
    head =
      s
      |> String.trim()
      |> String.upcase()
      |> String.split(["+", " ", "\t"], parts: 2)
      |> hd()

    case head do
      "PENDING" -> :pending
      "CONFIGURING" -> :pending
      "REQUEUED" -> :pending
      "RESV_DEL_HOLD" -> :pending
      "SUSPENDED" -> :pending
      "RUNNING" -> :running
      "COMPLETING" -> :running
      "SIGNALING" -> :running
      "STAGE_OUT" -> :running
      "COMPLETED" -> :completed
      "FAILED" -> :failed
      "BOOT_FAIL" -> :failed
      "DEADLINE" -> :failed
      "SPECIAL_EXIT" -> :failed
      "TIMEOUT" -> :timeout
      "OUT_OF_MEMORY" -> :oom
      "OOM" -> :oom
      "CANCELLED" -> :cancelled
      "REVOKED" -> :cancelled
      "NODE_FAIL" -> :node_fail
      "PREEMPTED" -> :preempted
      _ -> :unknown
    end
  end

  @doc """
  Update a job from a parsed Slurm record (a map shaped like the result of
  `Slurm.CLI.squeue/1` or `Slurm.CLI.sacct/1`). Unknown keys are ignored.
  Returns `{job, transition?}` where `transition?` is true iff `state` changed.
  """
  @spec update(t(), map()) :: {t(), boolean()}
  def update(%__MODULE__{} = job, fields) when is_map(fields) do
    raw = Map.get(fields, :state) || Map.get(fields, "state")
    parsed = parse_state(raw)

    # Refuse terminal -> non-terminal regressions. Once a job has
    # reached a terminal state, later refreshes (e.g. a delayed sacct
    # row reusing a recycled job id) must not flip it back.
    next =
      cond do
        terminal?(job.state) and not terminal?(parsed) -> job.state
        true -> parsed
      end

    new_job = %{
      job
      | state: next,
        raw_state: raw || job.raw_state,
        exit_code: get_int(fields, :exit_code) || job.exit_code,
        derived_exit_code: get_int(fields, :derived_exit_code) || job.derived_exit_code,
        reason: get_str(fields, :reason) || job.reason,
        elapsed: get_str(fields, :elapsed) || job.elapsed,
        max_rss: get_str(fields, :max_rss) || job.max_rss,
        updated_at: DateTime.utc_now()
    }

    {new_job, new_job.state != job.state}
  end

  defp get_int(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      n when is_integer(n) -> n
      n when is_binary(n) -> case Integer.parse(n) do
        {i, ""} -> i
        _ -> nil
      end
      _ -> nil
    end
  end

  defp get_str(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      s when is_binary(s) -> s
      _ -> nil
    end
  end
end
