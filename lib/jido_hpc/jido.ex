defmodule JidoHpc.Jido do
  @moduledoc """
  The Jido instance for this application.

  Defines a per-app supervision tree (Task supervisor, Registry, DynamicSupervisor)
  and exposes helpers like `start_agent/0`, `whereis/1`, `list_agents/0`. See
  `Jido` for the macro contract.
  """

  use Jido, otp_app: :jido_hpc
end
