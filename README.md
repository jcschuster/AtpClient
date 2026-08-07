# AtpClient

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.21839442.svg)](https://doi.org/10.5281/zenodo.21839442)

Elixir client for external automated theorem provers. Four backends are
supported:

- **SystemOnTPTP** — the public `tptp.org` HTTP form endpoint.
- **StarExec** — self-hosted StarExec deployments.
- **Isabelle** — `isabelle server` instances, via the
  [`isabelle_elixir`](https://hex.pm/packages/isabelle_elixir) package.
- **LocalExec** — a locally installed TPTP-compliant prover binary
  (E, Vampire, …) invoked via `System.cmd/3`.

All backends return results normalized to
`AtpClient.ResultNormalization.atp_result` — a `{:ok, status}` tuple whose
`status` is the SZS Ontology verdict downcased to an Elixir atom
(`:theorem`, `:unsatisfiable`, `:counter_satisfiable`, `:satisfiable`,
`:gave_up`, `:timeout`, …) — so that comparing provers across backends is
straightforward without conflating semantically distinct verdicts
(`:theorem` ≠ `:unsatisfiable`, `:counter_satisfiable` ≠ `:satisfiable`).
Errors that prevented any SZS verdict (network failure, malformed input,
missing binary) come back as `{:error, reason}`.

Each backend also implements the `AtpClient.Backend` behaviour
(`config_key/0`, `label/0`, `config_schema/0`, `verify/1`, `query/2`), so a
Smart Cell or other UI can enumerate backends via `AtpClient.backends/0`,
render their settings from `config_schema/0`, probe reachability with
`verify/1`, and run a TPTP problem with the uniform `query/2` entry point —
without hard-coding per-backend knowledge.

## Installation

Add `:atp_client` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:atp_client, "~> 0.6"}
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

config :atp_client, :local_exec,
  binary: "eprover",
  args: ["--auto", "--tstp-format", "--cpu-limit=10"],
  cpu_timeout_s: 10
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
# => ["Alt-Ergo---0.95.2", "Beagle---0.9.52", ...]

AtpClient.SystemOnTptp.query_system(problem, "cvc5---1.3.4", time_limit_sec: 10)
# => {:ok, :theorem}

AtpClient.SystemOnTptp.query_selected_systems(problem, ["cvc5---1.3.4", "Vampire---5.0.1"], time_limit_sec: 5)
# => {:ok, [{"cvc5---1.3.4", {:ok, :theorem}}, {"Vampire---5.0.1", {:ok, :theorem}}]}

AtpClient.SystemOnTptp.query_all_systems(problem, time_limit_sec: 5)
# => {:ok, [{"Alt-Ergo---0.95.2", {:ok, :theorem}}, ...]}
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
# => {:ok, :theorem}

AtpClient.StarExec.logout(session)
```

StarExec's job-creation form accepts a large, version-dependent set of
fields; `create_job/3` therefore takes an open-ended map and leaves the exact
field names to the caller. The `request/4` low-level helper is available for
any endpoint this module does not wrap directly.

### Isabelle

Isabelle needs a running `isabelle server` to talk to. If `isabelle` is on
your `PATH` (or reachable via `ISABELLE_TOOL`), the bundled
[`isabelle_elixir`](https://hex.pm/packages/isabelle_elixir) package can
start one for you — no manual `isabelle server` invocation required:

```elixir
{:ok, server} = IsabelleClient.start_server()
opts = [host: server.host, port: server.port, password: server.password]

theory = ~S"""
lemma "\<forall>x. P x \<longrightarrow> P x"
  by auto
"""

# Bare-body input is auto-wrapped in `theory ... imports Main begin ... end`.
# `prove_theory/4` returns the single-wrapped `atp_result()` shape every
# other backend already uses.
{:ok, session} = AtpClient.Isabelle.open_session(opts)
{:ok, :theorem} = AtpClient.Isabelle.prove_theory(session, theory, "Example")
:ok = AtpClient.Isabelle.close_session(session)

# When you're done:
IsabelleClient.Server.kill(server.name)
```

Point at an already-running server by dropping the `start_server/0` call and
supplying the coordinates directly, either per-call or via `config.exs`. In
containerised or Cygwin setups where the BEAM and Isabelle see the shared
theory directory under different paths, set both `:local_dir` (BEAM view)
and `:isabelle_dir` (server view); when they match, only `:local_dir` (or
neither — it defaults to a subdirectory of `System.tmp_dir!/0`) is needed.

Sessions are cheap to keep open and expensive to restart. Reuse one across
multiple theories:

```elixir
{:ok, session} = AtpClient.Isabelle.open_session(opts)
try do
  {:ok, :theorem} = AtpClient.Isabelle.prove_theory(session, theory, "Example")
  {:ok, :theorem} = AtpClient.Isabelle.prove_theory(session, other_theory, "Other")
after
  AtpClient.Isabelle.close_session(session)
end
```

> The three-arity `AtpClient.Isabelle.query/3` is deprecated as of 0.6.0 but
> still available for callers that depend on its double-wrapped return shape
> (`{:ok, {:ok, :theorem}}`).

Pass a TPTP/THF problem string to `query_tptp/2` (or `prove_tptp/3` with a
session) to route it through `IsabelleClient.TPTP.isabellize_theory/1` and
get one result per conjecture:

```elixir
problem = ~S"""
thf(p_type, type, p: $i > $o).
thf(g, conjecture, ! [X: $i]: (p @ X | ~ (p @ X))).
"""

AtpClient.Isabelle.query_tptp(problem, opts)
# => {:ok, [%{name: "g", result: {:ok, :theorem}}]}
```

Pass `raw: true` to `prove_theory/4` to inspect the full `use_theories`
payload instead of the classified verdict.

### LocalExec

```elixir
problem = """
fof(ax1, axiom, p).
fof(ax2, axiom, (p => q)).
fof(goal, conjecture, q).
"""

# `binary` is resolved against $PATH or used as an absolute path; `args`
# may contain "{{problem}}" to pin the problem-file position (otherwise the
# path is appended last).
AtpClient.LocalExec.query(problem,
  binary: "eprover",
  args: ["--auto", "--tstp-format", "--cpu-limit=10"]
)
# => {:ok, :theorem}
```

`scripts/build_eprover.sh` builds the E theorem prover from source and
installs it into `priv/bin/` for use as the LocalExec binary.

### Uniform backend interface

Every backend module also implements `AtpClient.Backend`, which is what the
Smart Cell uses to render a configuration form and dispatch a run:

```elixir
for module <- AtpClient.backends() do
  %{
    key:    module.config_key(),    # :sotptp | :starexec | :isabelle | :local_exec
    label:  module.label(),         # "SystemOnTPTP", "StarExec", ...
    fields: module.config_schema()  # [%AtpClient.Config.Field{...}, ...]
  }
end

# Once a form is filled out, probe reachability before submitting work:
AtpClient.StarExec.verify(
  base_url: "https://starexec.example.org",
  username: "...",
  password: "..."
)
# => :ok | {:error, reason}

# And run a problem through any backend uniformly:
AtpClient.LocalExec.query(problem, binary: "eprover")
AtpClient.SystemOnTptp.query(problem, default_system: "cvc5---1.3.2")
```

## License

MIT.
