# AtpClient

Elixir client for external automated theorem provers. Three backends are
supported:

- **SystemOnTPTP** — the public `tptp.org` HTTP form endpoint.
- **StarExec** — self-hosted StarExec deployments.
- **Isabelle** — `isabelle server` instances, via the
  [`isabelle_elixir`](https://hex.pm/packages/isabelle_elixir) package.

All backends return results normalized to
`AtpClient.ResultNormalization.atp_result` so that comparing provers across
backends is straightforward and can be used in downstream tasks.

This package was developed at the
[University of Bamberg](https://www.uni-bamberg.de/en/) with the
[Chair for AI Systems Engineering](https://www.uni-bamberg.de/en/aise/).

## Installation

Add `:atp_client` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:atp_client, "~> 0.1"}
  ]
end
```

## Configuration

Settings are resolved from three sources, in increasing precedence:

1. Library defaults (declared in `AtpClient`'s `mix.exs`).
2. Application environment (typically `config/config.exs`).
3. Per-call keyword options passed to the relevant function.

Only the settings required by the backends you actually use need to be set.

```elixir
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
```

Any setting may be overridden for a single call:

```elixir
AtpClient.Isabelle.query(theory, "Example", session: "Main", raw: true)
```

## Usage

### SystemOnTPTP

```elixir
problem = """
fof(ax1, axiom, p).
fof(ax2, axiom, (p => q)).
fof(goal, conjecture, q).
"""

AtpClient.SystemOnTptp.list_provers()
# => ["Alt-Ergo---0.95.2", "cvc5---1.3.0", ...]

AtpClient.SystemOnTptp.query_system(problem, "cvc5---1.3.0", time_limit_sec: 10)
# => {:ok, :thm}

AtpClient.SystemOnTptp.query_selected_systems(problem, ["cvc5---1.3.0", "Vampire---5.0"], time_limit_sec: 5)
# => {:ok, [{"cvc5---1.3.0", {:ok, :thm}}, {"Vampire---5.0", {:ok, :thm}}]}

AtpClient.SystemOnTptp.query_all_systems(problem, time_limit_sec: 5)
# => {:ok, [{"Alt-Ergo---0.95.3", {:ok, :thm}}, ...]}
```

### StarExec

```elixir
{:ok, session} = AtpClient.StarExec.login()

{:ok, response} =
  AtpClient.StarExec.create_job(session, %{
    "name" => "smoke-test",
    "sid" => 42,
    "queue" => 1,
    "cpuTimeout" => 30,
    "wallclockTimeout" => 30,
    # ... solver / benchmark fields as your instance expects
  })

job_id = extract_job_id(response)   # deployment-specific

{:ok, info} = AtpClient.StarExec.wait_for_job(session, job_id, timeout_ms: 600_000)

# Pair ids come from `info`; stdout is then normalized the same way as
# SystemOnTPTP output:
{:ok, stdout} = AtpClient.StarExec.get_pair_stdout(session, pair_id)
AtpClient.ResultNormalization.interpret_result(stdout)
# => {:ok, :thm}

AtpClient.StarExec.logout(session)
```

StarExec's job-creation form accepts a large, version-dependent set of
fields; `create_job/3` therefore takes an open-ended map and leaves the exact
field names to the caller. The `request/4` low-level helper is available for
any endpoint this module does not wrap directly.

### Isabelle

```elixir
theory = ~S"""
theory Example imports Main
begin

lemma "\<forall>x. P x \<longrightarrow> P x"
  by auto

end
"""

# The first result in the output is interpreted. "Successful" tool calls, e.g.
# finding a proof or countermodel, take precedence. Multiple formulae are not
# supported.
AtpClient.Isabelle.query(theory, "Example")
# => {:ok, {:ok, :thm}}

# With an existing session, reuse the socket for multiple theories:
{:ok, session} = AtpClient.Isabelle.open_session()
AtpClient.Isabelle.prove_theory(session, theory, "Example")
AtpClient.Isabelle.prove_theory(session, other_theory, "Example2")
AtpClient.Isabelle.close_session(session)

# Pass `raw: true` to inspect the full Isabelle status list instead:
{:ok, status} = AtpClient.Isabelle.query(theory, "Example", raw: true)
AtpClient.ResultNormalization.extract_isabelle_text(status)
# => "...\nSledgehammering...\nverit found a proof...\n..."
```

## License

MIT.
