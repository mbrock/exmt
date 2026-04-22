defmodule ExmtCLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :exmt_cli,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp escript do
    [
      main_module: Exmt.CLI,
      name: "exmt"
    ]
  end

  defp deps do
    [
      {:exmt, path: ".."}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format",
        "test"
      ]
    ]
  end
end
