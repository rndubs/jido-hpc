defmodule JidoHpc.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      JidoHpc.Jido
    ]

    opts = [strategy: :one_for_one, name: JidoHpc.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
