defmodule AtpClient.MixProject do
  use Mix.Project

  @version "0.2.2"
  @source_url "https://github.com/jcschuster/AtpClient"

  def project do
    [
      app: :atp_client,
      version: @version,
      elixir: "~> 1.19",
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
      mod: {AtpClient.Application, []},
      env: [
        sotptp: [
          url: "https://tptp.org/cgi-bin/SystemOnTPTPFormReply",
          auto_refresh: true,
          refresh_timeout_ms: 15_000,
          default_time_limit_sec: 5
        ],
        starexec: [
          # base_url is required at call time; no sensible default
          # e.g. "https://starexec.example.org/starexec"
          request_timeout_ms: 30_000,
          poll_interval_ms: 2_000,
          # Endpoint paths, overridable for non-standard deployments
          login_path: "/j_security_check",
          logout_path: "/services/session/logout",
          job_info_path: "/services/jobs",
          pair_stdout_path: "/services/jobs/pairs"
        ],
        isabelle: [
          host: "127.0.0.1",
          port: 9999,
          # password, local_dir, isabelle_dir are required at call time
          session: "HOL",
          session_start_timeout_ms: 120_000,
          use_theories_timeout_ms: 120_000
        ]
      ]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:isabelle_elixir, "~> 0.3"},
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
      extras: ["README.md", "examples/demo.livemd"],
      groups_for_modules: [
        "Backend integrations": [
          AtpClient.StarExec,
          AtpClient.StarExec.Session,
          AtpClient.Isabelle,
          AtpClient.Isabelle.Session,
          AtpClient.TptpSystems
        ],
        Support: [
          AtpClient.Config,
          AtpClient.ResultNormalization
        ]
      ],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
