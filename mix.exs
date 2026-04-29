defmodule JidoHpc.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_hpc,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {JidoHpc.Application, []}
    ]
  end

  defp deps do
    [
      {:jido, "~> 2.2"},
      {:jido_ai, "~> 2.1"},
      # req_llm is pulled in transitively by :jido_ai. Add an explicit
      # version pin here only if we need to constrain it.
      {:jason, "~> 1.4"}
    ]
  end
end
