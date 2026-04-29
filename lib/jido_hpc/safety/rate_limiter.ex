defmodule JidoHpc.Safety.RateLimiter do
  @moduledoc """
  Caps the number of concurrent subprocess invocations the agent will
  spawn on a login node. Login nodes are shared with other users; an
  unbounded fan-out of `grep -r` or `git log` calls is antisocial and
  may get the user's account suspended.

  Usage:

      RateLimiter.run(fn -> System.cmd("grep", [...]) end)

  Returns whatever `fun` returns, or `{:error, :rate_limited}` if the
  caller could not acquire a slot before `:timeout` (ms, default 5_000).

  The cap defaults to `8` concurrent slots and can be overridden via
  `Application.put_env(:jido_hpc, :rate_limiter_max_concurrency, N)` or
  by passing `max_concurrency:` at start time.
  """

  use GenServer

  @default_max_concurrency 8
  @default_acquire_timeout 5_000

  # ---- Public API --------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Run `fun` while holding a slot. Returns `fun.()`'s value, or
  `{:error, :rate_limited}` if a slot couldn't be acquired in time.
  """
  @spec run((-> term()), keyword()) :: term() | {:error, :rate_limited}
  def run(fun, opts \\ []) when is_function(fun, 0) do
    name = Keyword.get(opts, :name, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_acquire_timeout)

    case acquire(name, timeout) do
      :ok ->
        try do
          fun.()
        after
          release(name)
        end

      :rate_limited ->
        {:error, :rate_limited}
    end
  end

  @doc "Returns `{in_use, max}` for inspection."
  @spec stats(GenServer.server()) :: {non_neg_integer(), pos_integer()}
  def stats(name \\ __MODULE__) do
    GenServer.call(name, :stats)
  end

  defp acquire(name, timeout) do
    GenServer.call(name, :acquire, timeout)
  catch
    :exit, {:timeout, _} -> :rate_limited
  end

  defp release(name), do: GenServer.cast(name, :release)

  # ---- GenServer ---------------------------------------------------------

  @impl true
  def init(opts) do
    max =
      Keyword.get(opts, :max_concurrency) ||
        Application.get_env(:jido_hpc, :rate_limiter_max_concurrency, @default_max_concurrency)

    {:ok, %{in_use: 0, max: max}}
  end

  @impl true
  def handle_call(:acquire, _from, %{in_use: in_use, max: max} = state) when in_use < max do
    {:reply, :ok, %{state | in_use: in_use + 1}}
  end

  def handle_call(:acquire, _from, state) do
    {:reply, :rate_limited, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, {state.in_use, state.max}, state}
  end

  @impl true
  def handle_cast(:release, %{in_use: in_use} = state) when in_use > 0 do
    {:noreply, %{state | in_use: in_use - 1}}
  end

  def handle_cast(:release, state), do: {:noreply, state}
end
