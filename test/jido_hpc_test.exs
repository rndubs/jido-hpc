defmodule JidoHpcTest do
  use ExUnit.Case, async: true

  test "application starts and Jido instance is supervised" do
    # The Jido instance is started in JidoHpc.Application; if compilation
    # and supervision wiring is correct, the registry will exist.
    assert is_pid(Process.whereis(JidoHpc.Supervisor))
    Code.ensure_loaded(JidoHpc.Jido)
    assert function_exported?(JidoHpc.Jido, :start_agent, 1)
  end

  test "config loads autonomy default" do
    assert Application.get_env(:jido_hpc, :autonomy) in [:confirm_on_submit, :autonomous]
  end

  test "path_allowlist is configured" do
    allowlist = Application.get_env(:jido_hpc, :path_allowlist)
    assert is_list(allowlist) and allowlist != []
  end
end
