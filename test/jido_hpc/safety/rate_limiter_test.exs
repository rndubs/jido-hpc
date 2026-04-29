defmodule JidoHpc.Safety.RateLimiterTest do
  use ExUnit.Case, async: true

  alias JidoHpc.Safety.RateLimiter

  setup do
    name = :"rate_limiter_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = RateLimiter.start_link(name: name, max_concurrency: 2)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, name: name}
  end

  test "runs the function and returns its value", %{name: name} do
    assert RateLimiter.run(fn -> :ran end, name: name) == :ran
  end

  test "exposes stats", %{name: name} do
    assert RateLimiter.stats(name) == {0, 2}
  end

  test "blocks when at capacity, returns rate-limited on timeout", %{name: name} do
    me = self()

    pid1 =
      spawn_link(fn ->
        RateLimiter.run(
          fn ->
            send(me, :slot1_acquired)

            receive do
              :release -> :ok
            end
          end,
          name: name
        )
      end)

    pid2 =
      spawn_link(fn ->
        RateLimiter.run(
          fn ->
            send(me, :slot2_acquired)

            receive do
              :release -> :ok
            end
          end,
          name: name
        )
      end)

    assert_receive :slot1_acquired, 500
    assert_receive :slot2_acquired, 500

    # third caller should be unable to acquire within a tight timeout
    assert RateLimiter.run(fn -> :should_not_run end, name: name, timeout: 50) ==
             {:error, :rate_limited}

    send(pid1, :release)
    send(pid2, :release)
  end

  test "releases slot even if fun raises", %{name: name} do
    assert {0, 2} = RateLimiter.stats(name)

    assert_raise RuntimeError, "boom", fn ->
      RateLimiter.run(fn -> raise "boom" end, name: name)
    end

    # let the cast process
    Process.sleep(10)
    assert {0, 2} = RateLimiter.stats(name)
  end
end
