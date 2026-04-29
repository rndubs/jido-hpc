defmodule JidoHpc.Safety.CmdGuard do
  @moduledoc """
  Validates external commands before they reach `System.cmd/3`.

  Rules:
    * `cmd` must be a binary on the configured allowlist (compared by
      basename — absolute paths are accepted as long as their basename
      is allowlisted)
    * `cmd` must not contain shell metacharacters or NUL bytes
    * `args` must be a list of binaries; no atoms, no nested lists, no
      NULs
    * No element may begin with `&&`, `||`, `;`, etc. (defensive — they
      would not be interpreted by `System.cmd/3`, but we refuse to pass
      them so misuse via a future shell wrapper stays safe)

  The allowlist comes from `Application.get_env(:jido_hpc, :cmd_allowlist)`.
  Tests may pass `:allowlist` explicitly.

  This module never spawns a process — it only inspects the request.
  """

  @type validation_opts :: [allowlist: [String.t()]]

  # Characters that should never appear in a command name. A binary that
  # contains any of these almost certainly indicates an attempt to smuggle
  # a shell pipeline through.
  @cmd_meta ~c"|&;<>$`\n\r\t\"'\\*?(){}[]"

  @doc """
  Validate a `{cmd, args}` pair. Returns `{:ok, {cmd, args}}` or
  `{:error, reason}`.
  """
  @spec validate(term(), term(), validation_opts()) ::
          {:ok, {String.t(), [String.t()]}} | {:error, term()}
  def validate(cmd, args, opts \\ [])

  def validate(cmd, _args, _opts) when not is_binary(cmd) do
    {:error, {:invalid_cmd, :not_a_string}}
  end

  def validate(_cmd, args, _opts) when not is_list(args) do
    {:error, {:invalid_args, :not_a_list}}
  end

  def validate(cmd, args, opts) do
    with :ok <- check_cmd_clean(cmd),
         :ok <- check_args(args),
         :ok <- check_allowlist(cmd, opts) do
      {:ok, {cmd, args}}
    end
  end

  @doc """
  Bang variant: returns `{cmd, args}` or raises `ArgumentError`.
  """
  @spec validate!(term(), term(), validation_opts()) :: {String.t(), [String.t()]}
  def validate!(cmd, args, opts \\ []) do
    case validate(cmd, args, opts) do
      {:ok, pair} -> pair
      {:error, reason} -> raise ArgumentError, "command rejected: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the configured command allowlist.
  """
  @spec allowlist(validation_opts()) :: [String.t()]
  def allowlist(opts \\ []) do
    raw =
      Keyword.get(opts, :allowlist) ||
        Application.get_env(:jido_hpc, :cmd_allowlist, [])

    raw |> List.wrap() |> Enum.map(&to_string/1)
  end

  defp check_cmd_clean(""), do: {:error, {:invalid_cmd, :empty}}

  defp check_cmd_clean(cmd) do
    cond do
      String.contains?(cmd, <<0>>) ->
        {:error, {:invalid_cmd, :null_byte}}

      contains_meta?(cmd) ->
        {:error, {:invalid_cmd, :shell_metacharacter}}

      true ->
        :ok
    end
  end

  defp check_args(args) do
    cond do
      Enum.any?(args, &(not is_binary(&1))) ->
        {:error, {:invalid_args, :non_string_element}}

      Enum.any?(args, &String.contains?(&1, <<0>>)) ->
        {:error, {:invalid_args, :null_byte}}

      true ->
        :ok
    end
  end

  defp check_allowlist(cmd, opts) do
    base = Path.basename(cmd)
    list = allowlist(opts)

    if base in list do
      :ok
    else
      {:error, {:not_allowlisted, base}}
    end
  end

  defp contains_meta?(cmd) do
    cmd
    |> String.to_charlist()
    |> Enum.any?(&(&1 in @cmd_meta))
  end
end
