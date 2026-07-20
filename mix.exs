defmodule AtpClient.MixProject do
  use Mix.Project

  @version "0.6.1"
  @source_url "https://github.com/jcschuster/AtpClient"

  def project do
    [
      app: :atp_client,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "AtpClient",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AtpClient.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.6"},
      {:nimble_options, "~> 1.1"},
      {:isabelle_elixir, "~> 0.4"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Elixir client for automated theorem provers via SystemOnTPTP, " <>
      "StarExec, and Isabelle servers."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README* LICENSE* CHANGELOG* examples/*.livemd)
    ]
  end

  defp docs do
    [
      main: "AtpClient",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "examples/demo.livemd"
      ],
      groups_for_extras: [
        Examples: ["examples/demo.livemd"]
      ],
      # The CHANGELOG documents APIs that were renamed or removed in past
      # releases; ExDoc would otherwise warn on each historical reference.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_modules: [
        "Backend integrations": [
          AtpClient.Backend,
          AtpClient.SystemOnTptp,
          AtpClient.SystemOnTptp.Provers,
          AtpClient.StarExec,
          AtpClient.StarExec.Session,
          AtpClient.Isabelle,
          AtpClient.Isabelle.Session,
          AtpClient.LocalExec
        ],
        Lint: [
          AtpClient.Lint,
          AtpClient.Lint.Local,
          AtpClient.Lint.Tptp4x,
          AtpClient.Lint.Diagnostic,
          AtpClient.Lint.Symbol,
          AtpClient.Lint.Report
        ],
        Support: [
          AtpClient.Config,
          AtpClient.Config.Field,
          AtpClient.ResultNormalization
        ]
      ],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
