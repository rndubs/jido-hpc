defmodule JidoHpc.Config do
  @moduledoc """
  Boot-time configuration checks for `jido_hpc`.

  Currently exposes a single preflight, `api_key_status/0`, which asks
  `ReqLLM.Keys` whether the configured `:jido_ai, :default_model`
  provider has a usable API key in any of the standard locations
  (per-request opts, `Application` env, or system env / `.env`).

  The REPL calls this before entering its read loop so a missing key
  surfaces as a clear, actionable message instead of a stack trace
  out of `req_llm` after the user types their first prompt.
  """

  @type provider :: atom()

  @type ok :: {:ok, %{provider: provider(), source: :option | :application | :system}}
  @type err :: {:error, String.t()}

  @doc """
  Returns the provider atom for the configured `:jido_ai, :default_model`.

  Accepts the two shapes jido_ai supports for that config value:

    * `{provider, model_name}` — e.g. `{:anthropic, "claude-sonnet-4-6"}`
    * a `ReqLLM.Model{}` / `LLMDB.Model{}` struct with a `:provider` field

  Falls back to `:anthropic` when no model is configured. Returns
  `{:error, reason}` if the value is a shape we don't recognize — we'd
  rather surface the misconfig than guess.
  """
  @spec default_provider() :: {:ok, provider()} | err()
  def default_provider do
    case Application.get_env(:jido_ai, :default_model) do
      nil ->
        {:ok, :anthropic}

      {provider, _model} when is_atom(provider) ->
        {:ok, provider}

      %{provider: provider} when is_atom(provider) ->
        {:ok, provider}

      other ->
        {:error,
         "Unrecognized :jido_ai, :default_model value: #{inspect(other)}. " <>
           "Expected {:provider, \"model_name\"} or %ReqLLM.Model{}."}
    end
  end

  @doc """
  Verify the configured provider has a usable API key.

  Returns `{:ok, %{provider: ..., source: ...}}` when a key is found
  (with `source` indicating where), or `{:error, message}` with a
  human-readable message that names the exact env var and config key
  to set.
  """
  @spec api_key_status() :: ok() | err()
  def api_key_status do
    with {:ok, provider} <- default_provider(),
         {:ok, _key, source} <- ReqLLM.Keys.get(provider, []) do
      {:ok, %{provider: provider, source: source}}
    else
      {:error, %ReqLLM.Error.Invalid.Parameter{parameter: msg}} ->
        {:error, format_missing_key(msg)}

      {:error, msg} when is_binary(msg) ->
        {:error, format_missing_key(msg)}

      {:error, _} = err ->
        err
    end
  end

  defp format_missing_key(req_llm_msg) do
    """
    No API key found for the configured LLM provider.

    req_llm reported: #{req_llm_msg}

    To fix, set one of:
      * export ANTHROPIC_API_KEY=sk-ant-...   (or the equivalent for your provider)
      * config :req_llm, :anthropic_api_key, "sk-ant-..."
      * a `.env` file in the project root with ANTHROPIC_API_KEY=...

    Read-only ops (mix test, mix compile) do not need a key — only the
    live REPL and any direct LLM calls do.
    """
  end
end
