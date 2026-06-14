defmodule AtpClient do
  @moduledoc """
  Elixir client for external automated theorem provers.

  Four backends are supported:

    * **SystemOnTPTP** — public tptp.org HTTP form API; see
      `AtpClient.SystemOnTptp`.
    * **StarExec** — self-hosted StarExec instances; see `AtpClient.StarExec`.
    * **Isabelle** — `isabelle server` instances via `isabelle_elixir`; see
      `AtpClient.Isabelle`.
    * **LocalExec** — a locally installed TPTP-compliant prover binary
      (e.g. E, Vampire) invoked via `System.cmd/3`; see `AtpClient.LocalExec`.
      Run `scripts/build_eprover.sh` to install E into `priv/bin/`.

  Each backend reads its settings through `AtpClient.Config`, which layers
  `config/config.exs` on top of the library defaults and lets per-call options
  override everything. See the `AtpClient.Config` module docs for details.


  ## Configuration

  Settings are resolved from three sources, in increasing precedence:

  1. Library defaults (declared in `AtpClient`'s `mix.exs`).
  2. Application environment (typically `config/config.exs`).
  3. Per-call keyword options passed to the relevant function.

  Only the settings required by the backends you actually use need to be set.

      # config/config.exs
      import Config

      config :atp_client, :sotptp,
        # The default points at tptp.org; override for a mirror or internal
        # deployment:
        url: "https://tptp.org/cgi-bin/SystemOnTPTPFormReply",
        default_time_limit_sec: 10

      config :atp_client, :starexec,
        base_url: "https://starexec.example.org/starexec",
        username: System.get_env("STAREXEC_USER"),
        password: System.get_env("STAREXEC_PASS")

      config :atp_client, :isabelle,
        host: "isabelle.example.org",
        port: 9999,
        password: System.get_env("ISABELLE_PASSWORD"),
        # Directory shared between this node and the Isabelle server. If the two
        # see the same files under different paths (e.g. because one runs inside
        # a container), set `isabelle_dir` separately:
        local_dir: "/shared/problems",
        isabelle_dir: "/shared/problems",
        session: "HOL"

      config :atp_client, :local_exec,
        binary: "eprover",
        args: ["--auto", "--tstp-format", "--cpu-limit=10"],
        cpu_timeout_s: 10

  Any setting may be overridden for a single call:

      AtpClient.Isabelle.query(theory, session: "Main", raw: true)
  """
end
