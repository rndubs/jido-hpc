defmodule JidoHpc.Slurm.JobSpec do
  @moduledoc """
  Typed description of a Slurm batch job.

  The agent's LLM never writes `#SBATCH` lines directly — instead it fills
  one of these structs and `JidoHpc.Slurm.Script.render/1` produces the
  sbatch script. This guarantees:

    * No injection via crafted directive lines.
    * The full request is auditable in a single struct.
    * Defaults are applied uniformly (e.g. `output`, `error`, `workdir`).

  ## Fields

    * `name`          — job name (`#SBATCH --job-name`). Required.
    * `time`          — wall-clock limit, `"HH:MM:SS"` or `"D-HH:MM:SS"`. Required.
    * `nodes`         — number of nodes (`-N`). Default `1`.
    * `ntasks`        — total MPI ranks (`-n`). Default `1`.
    * `cpus_per_task` — `--cpus-per-task`. Default `1`.
    * `mem`           — `--mem`, e.g. `"32G"`. Optional.
    * `gpus`          — number of GPUs (`--gres=gpu:N`). Optional.
    * `partition`     — `-p`. Optional.
    * `modules`       — Lmod modules to load before the command runs.
    * `env`           — extra environment variables (key/value strings).
    * `workdir`       — `--chdir`. Required (must be allowlisted).
    * `command`       — the command to run, as an arg list.
    * `array`         — `--array`, e.g. `"0-99%10"`. Optional.
    * `dependency`    — `--dependency`, e.g. `"afterok:12345"`. Optional.
    * `output`        — `--output` template. Default `"logs/%x-%j.out"`.
    * `error`         — `--error` template. Default `"logs/%x-%j.err"`.
    * `account`       — `-A`. Optional.
    * `qos`           — `--qos`. Optional.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          time: String.t(),
          nodes: pos_integer(),
          ntasks: pos_integer(),
          cpus_per_task: pos_integer(),
          mem: String.t() | nil,
          gpus: non_neg_integer() | nil,
          partition: String.t() | nil,
          modules: [String.t()],
          env: %{String.t() => String.t()},
          workdir: String.t(),
          command: [String.t()],
          array: String.t() | nil,
          dependency: String.t() | nil,
          output: String.t(),
          error: String.t(),
          account: String.t() | nil,
          qos: String.t() | nil
        }

  @enforce_keys [:name, :time, :workdir, :command]
  defstruct name: nil,
            time: nil,
            nodes: 1,
            ntasks: 1,
            cpus_per_task: 1,
            mem: nil,
            gpus: nil,
            partition: nil,
            modules: [],
            env: %{},
            workdir: nil,
            command: [],
            array: nil,
            dependency: nil,
            output: "logs/%x-%j.out",
            error: "logs/%x-%j.err",
            account: nil,
            qos: nil

  @time_re ~r/^(?:\d+-)?\d{1,2}:\d{2}:\d{2}$|^\d+$/
  # First character must be alphanumeric or underscore — prevents
  # `--`-prefixed flag injection into directive lines like
  # `#SBATCH --job-name=--uid=0`.
  @name_re ~r/^[A-Za-z0-9_][A-Za-z0-9._\-]*$/
  @env_key_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  # Conservative allowlist for free-form Slurm identifier fields.
  # Allows letters, digits, and the punctuation Slurm itself uses for
  # array specs (`-`, `:`, `,`, `%`), dependency lists (`:`, `,`,
  # `?`), partition/qos/account names (`.`, `_`), and a `+` for sacct
  # variant suffixes. Crucially: NO whitespace, `;`, `&`, `|`, `$`,
  # quotes, or `#` — those are how a hostile value would forge a new
  # `#SBATCH` directive line or comment out the rest of the script.
  @ident_re ~r/^[A-Za-z0-9_][A-Za-z0-9._:,%+\-?]*$/

  @doc """
  Construct a JobSpec from a map or keyword list, applying defaults and
  validating each field. Returns `{:ok, spec}` or `{:error, reason}`.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- fetch_string(attrs, :name),
         :ok <- validate_name(name),
         {:ok, time} <- fetch_string(attrs, :time),
         :ok <- validate_time(time),
         {:ok, workdir} <- fetch_string(attrs, :workdir),
         {:ok, command} <- fetch_command(attrs),
         {:ok, nodes} <- fetch_pos_int(attrs, :nodes, 1),
         {:ok, ntasks} <- fetch_pos_int(attrs, :ntasks, 1),
         {:ok, cpus} <- fetch_pos_int(attrs, :cpus_per_task, 1),
         {:ok, mem} <- fetch_optional_string(attrs, :mem),
         :ok <- validate_mem(mem),
         {:ok, gpus} <- fetch_non_neg_int(attrs, :gpus, nil),
         {:ok, partition} <- fetch_optional_string(attrs, :partition),
         :ok <- validate_ident(:partition, partition),
         {:ok, modules} <- fetch_string_list(attrs, :modules, []),
         {:ok, env} <- fetch_env(attrs),
         {:ok, array} <- fetch_optional_string(attrs, :array),
         :ok <- validate_ident(:array, array),
         {:ok, dependency} <- fetch_optional_string(attrs, :dependency),
         :ok <- validate_ident(:dependency, dependency),
         {:ok, output} <- fetch_string_or_default(attrs, :output, "logs/%x-%j.out"),
         {:ok, error} <- fetch_string_or_default(attrs, :error, "logs/%x-%j.err"),
         {:ok, account} <- fetch_optional_string(attrs, :account),
         :ok <- validate_ident(:account, account),
         {:ok, qos} <- fetch_optional_string(attrs, :qos),
         :ok <- validate_ident(:qos, qos) do
      {:ok,
       %__MODULE__{
         name: name,
         time: time,
         nodes: nodes,
         ntasks: ntasks,
         cpus_per_task: cpus,
         mem: mem,
         gpus: gpus,
         partition: partition,
         modules: modules,
         env: env,
         workdir: workdir,
         command: command,
         array: array,
         dependency: dependency,
         output: output,
         error: error,
         account: account,
         qos: qos
       }}
    end
  end

  @doc "Bang variant of `new/1`."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid JobSpec: #{inspect(reason)}"
    end
  end

  # --- field fetchers -----------------------------------------------------

  defp fetch_string(attrs, key) do
    case get(attrs, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:invalid, key, :required_string}}
    end
  end

  defp fetch_optional_string(attrs, key) do
    case get(attrs, key) do
      nil -> {:ok, nil}
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, {:invalid, key, :must_be_string_or_nil}}
    end
  end

  defp fetch_string_or_default(attrs, key, default) do
    case get(attrs, key) do
      nil -> {:ok, default}
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, {:invalid, key, :must_be_string}}
    end
  end

  defp fetch_pos_int(attrs, key, default) do
    case get(attrs, key) do
      nil -> {:ok, default}
      v when is_integer(v) and v > 0 -> {:ok, v}
      _ -> {:error, {:invalid, key, :must_be_pos_integer}}
    end
  end

  defp fetch_non_neg_int(attrs, key, default) do
    case get(attrs, key) do
      nil -> {:ok, default}
      v when is_integer(v) and v >= 0 -> {:ok, v}
      _ -> {:error, {:invalid, key, :must_be_non_neg_integer_or_nil}}
    end
  end

  defp fetch_string_list(attrs, key, default) do
    case get(attrs, key) do
      nil ->
        {:ok, default}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, {:invalid, key, :must_be_list_of_strings}}

      _ ->
        {:error, {:invalid, key, :must_be_list_of_strings}}
    end
  end

  defp fetch_command(attrs) do
    case get(attrs, :command) do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, {:invalid, :command, :must_be_list_of_strings}}

      _ ->
        {:error, {:invalid, :command, :required_non_empty_list}}
    end
  end

  defp fetch_env(attrs) do
    case get(attrs, :env) do
      nil ->
        {:ok, %{}}

      m when is_map(m) ->
        Enum.reduce_while(m, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          cond do
            not is_binary(k) or not Regex.match?(@env_key_re, k) ->
              {:halt, {:error, {:invalid, :env, {:bad_key, k}}}}

            not is_binary(v) ->
              {:halt, {:error, {:invalid, :env, {:bad_value, k}}}}

            String.contains?(v, "\n") ->
              {:halt, {:error, {:invalid, :env, {:newline_in_value, k}}}}

            true ->
              {:cont, {:ok, Map.put(acc, k, v)}}
          end
        end)

      _ ->
        {:error, {:invalid, :env, :must_be_map}}
    end
  end

  # --- field validators ---------------------------------------------------

  defp validate_name(name) do
    if Regex.match?(@name_re, name),
      do: :ok,
      else: {:error, {:invalid, :name, :unsafe_characters}}
  end

  defp validate_time(time) do
    if Regex.match?(@time_re, time),
      do: :ok,
      else: {:error, {:invalid, :time, :unrecognized_format}}
  end

  defp validate_mem(nil), do: :ok

  defp validate_mem(mem) do
    if Regex.match?(~r/^\d+[KMGT]?$/, mem),
      do: :ok,
      else: {:error, {:invalid, :mem, :unrecognized_format}}
  end

  defp validate_ident(_key, nil), do: :ok

  defp validate_ident(key, value) when is_binary(value) do
    if Regex.match?(@ident_re, value),
      do: :ok,
      else: {:error, {:invalid, key, :unsafe_characters}}
  end

  defp get(map, key) when is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end
end
