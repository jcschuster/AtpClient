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
          # Endpoint paths, overridable for non-standard deployments. Paths
          # include the `/starexec` servlet context — set `:base_url` to the
          # bare scheme/host (e.g. "https://starexec.example.org"), not the
          # context root.
          session_init_path: "/starexec/secure/index.jsp",
          login_path: "/starexec/j_security_check",
          logout_path: "/starexec/services/session/logout",
          job_info_path: "/starexec/services/details/job",
          job_output_path: "/starexec/secure/download",
          create_job_path: "/starexec/secure/add/job",
          upload_benchmarks_path: "/starexec/secure/upload/benchmarks",
          # Path template for "list every benchmark in this space"; "{space_id}"
          # is substituted at call time. POST endpoint, body ignored.
          list_space_benchmarks_path: "/starexec/services/job/{space_id}/allbench/pagination/",
          # StarExec's "no-type" benchmark processor — accepts any text file.
          # Override per call/install when you need TPTP-aware validation.
          benchmark_type: 1,
          # Worker queue id used by `prove/3` when not overridden in opts.
          queue_id: 1,
          # Defaults for the high-level prove/3 helper.
          cpu_timeout_s: 60
        ],
        isabelle: [
          host: "127.0.0.1",
          port: 9999,
          # password, local_dir, isabelle_dir are required at call time
          session: "HOL",
          session_start_timeout_ms: 120_000,
          use_theories_timeout_ms: 120_000
        ],
        local_exec: [
          # `binary` is required at call time (e.g. "eprover", "vampire").
          # Resolved via System.find_executable/1 unless an absolute path is given.
          args: [],
          cpu_timeout_s: 60,
          # Wall-clock timeout defaults to `cpu_timeout_s + 10` seconds at
          # call time when unset, giving the prover a chance to emit a clean
          # `SZS status Timeout` before the BEAM-side kill fires.
          wall_timeout_ms: nil
        ]
      ]
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
          AtpClient.StarExec,
          AtpClient.StarExec.Session,
          AtpClient.Isabelle,
          AtpClient.Isabelle.Session,
          AtpClient.LocalExec,
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
