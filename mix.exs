defmodule AtpClient.MixProject do
  use Mix.Project

  @version "0.8.1"
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
      docs: docs(),
      # The mix tasks call Mix, which is not in the default PLT.
      dialyzer: [plt_add_apps: [:mix]]
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
      {:tptp, "~> 0.2"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.7"},
      {:nimble_options, "~> 1.1"},
      {:isabelle_elixir, "~> 0.4"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Elixir client for automated theorem provers via SystemOnTPTP, " <>
      "StarExec, Isabelle servers and local binaries, on the tptp library."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "DOI" => "https://doi.org/10.5281/zenodo.21839441",
        "tptp" => "https://hex.pm/packages/tptp"
      },
      files:
        ~w(lib priv/system_on_tptp mix.exs README* LICENSE* CHANGELOG* CITATION.cff examples/*.livemd)
    ]
  end

  defp docs do
    [
      main: "AtpClient",
      logo: "assets/logo.svg",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "examples/demo.livemd",
        "priv/system_on_tptp/SYSTEMS.md": [filename: "systems", title: "SystemOnTPTP systems"]
      ],
      groups_for_extras: [
        Examples: ["examples/demo.livemd"],
        Systems: ["priv/system_on_tptp/SYSTEMS.md"]
      ],
      # The CHANGELOG documents APIs that were renamed or removed in past
      # releases; ExDoc would otherwise warn on each historical reference.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_modules: [
        "Backend integrations": [
          AtpClient.Backend,
          AtpClient.SystemOnTptp,
          AtpClient.SystemOnTptp.Reply,
          AtpClient.StarExec,
          AtpClient.StarExec.Session,
          AtpClient.Isabelle,
          AtpClient.Isabelle.Session,
          AtpClient.LocalExec
        ],
        "Inputs and results": [
          AtpClient.Input,
          AtpClient.Problem,
          AtpClient.Result,
          AtpClient.Verdict,
          AtpClient.Isabelle.Verdict
        ],
        Solutions: [
          AtpClient.Interpretation,
          AtpClient.Interpretation.Standard,
          AtpClient.Interpretation.VampireFmb,
          AtpClient.Interpretation.FiRoles,
          AtpClient.Isabelle.Nitpick
        ],
        Systems: [
          AtpClient.System,
          AtpClient.SystemOnTptp.SystemInfo,
          AtpClient.SystemOnTptp.Systems,
          AtpClient.SystemOnTptp.Audit
        ],
        "Mix tasks": [
          Mix.Tasks.AtpClient.Systems.Refresh,
          Mix.Tasks.AtpClient.Systems.Audit
        ],
        Analyzers: [
          AtpClient.Analyzer.Tptp4x
        ],
        Support: [
          AtpClient.Config,
          AtpClient.Config.Field
        ]
      ],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
