defmodule AtpClient.MixProject do
  use Mix.Project

  @version "0.2.2"
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
      # Library defaults live in `AtpClient.Config` (`@defaults`), not in
      # an `:env` block here. The `:env` mechanism only seeds Application
      # env at load time and is replaced wholesale by any user
      # `config :atp_client, :<backend>, …` — which silently dropped
      # defaults the user did not re-set. Merging per-key inside
      # `Config.get/2` keeps each unset key on its default regardless of
      # what the user configures.
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:isabelle_elixir, github: "davfuenmayor/isabelle_elixir", branch: "main"},
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
      files: ~w(lib mix.exs README* LICENSE*)
    ]
  end

  defp docs do
    [
      main: "AtpClient",
      extras: ["README.md", "examples/demo.livemd", "examples/isabelle_tptp.livemd"],
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
