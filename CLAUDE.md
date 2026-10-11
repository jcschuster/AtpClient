# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`atp_client` is an Elixir library exposing a single, normalized interface to four backends for automated theorem provers:

- **`AtpClient.SystemOnTptp`** — public `tptp.org` HTTP form API.
- **`AtpClient.StarExec`** — self-hosted StarExec (Tomcat) instances, driven through the same URLs the web UI uses.
- **`AtpClient.Isabelle`** — `isabelle server` over the `:isabelle_elixir` package.
- **`AtpClient.LocalExec`** — locally installed TPTP-compliant binary (E, Vampire, …) invoked via `Port.open/2`.

The library sits on [`tptp`](https://github.com/jcschuster/tptp) (`{:tptp, "~> 0.1.3"}`), which owns the TPTP language: reading, linting, printing, and the SZS ontology and status-line reader. AtpClient is the transport to the provers and never parses what it sends.

Every backend takes an `AtpClient.Problem` (a protocol: `binary()`, `iodata()`, `Tptp.File`, `Tptp.Unit`) and returns `{:ok, %AtpClient.Result{}}` or `{:error, reason}`. `Result.status` is a `Tptp.Szs.Ontology` value read from the system's output by `AtpClient.Verdict` (SZS status line via `Tptp.Szs.status/1`, then SystemOnTPTP's `says` summary, then prover-specific patterns); `evidence` says which of the three it was (`:szs`, `{:pattern, text}`, `{:backend, module}` for Isabelle); `output` is the raw output; `blocks` the delimited SZS output blocks; `Result.proof/1` reads a proof block as TPTP. A status word outside the ontology is `{:error, {:unknown_szs_status, word}}` — atoms are never created from prover output. Backend-specific error shapes (Isabelle's `{:isabelle_failed, …}`, LocalExec's `{:prover_not_found, …}`) are documented on each module.

Every backend additionally implements the `AtpClient.Backend` behaviour, which gives a Smart Cell or other UI a uniform handle: `config_key/0`, `label/0`, `config_schema/0` (a list of `AtpClient.Config.Field` structs), `verify/1`, and `query/2`. `AtpClient.backends/0` enumerates the four modules so UIs can discover them without hard-coding the list. `AtpClient.query/3` wraps a backend's `query/2` with the optional `preflight: true` (`AtpClient.preflight/1` = `Tptp.analyze/2`, rejecting on any error diagnostic); no backend parses on its own. Per-backend low-level entry points (`query_system/3`, `prove_theory/4`, `create_job/3`, `LocalExec.query_file/2`, …) remain available for callers that want sessions, multi-system fan-out, per-lemma detail, or a file passed to a prover by path.

## Commands

```bash
mix deps.get                       # fetch dependencies
mix compile
mix test                           # default suite; :local_prover tests are excluded
mix test --include local_prover    # also run the gated real-prover integration tests
mix test path/to/file_test.exs:42  # single test by line number
mix credo --all                    # lints
mix dialyzer                       # type checks (slow first run)
mix docs                           # ExDoc → ./doc/
scripts/build_eprover.sh           # builds E from source into priv/bin/eprover (for LocalExec)
```

Tests tagged `:local_prover` require a real prover binary on `PATH` (see `test/atp_client/local_exec_test.exs`). The default `ExUnit.start(exclude: [:local_prover])` skips them.

## Configuration layering

`AtpClient.Config` resolves settings by merging, in increasing precedence:

1. Library defaults declared in `mix.exs` under `application/0 -> :env`.
2. Application env (`config :atp_client, :<backend>, …`).
3. Per-call `opts` keyword list.

Use `Config.fetch!(backend, key, opts)` for settings without sensible defaults (`:base_url`, `:password`, `:local_dir`, `:binary`) and `Config.fetch(backend, key, default, opts)` for everything else. Any new backend setting must be declared in `mix.exs` `:env` for the defaults layer to work.

## Application supervision

`AtpClient.Application` starts:

- `AtpClient.TptpFinch` (Finch pool, HTTP/1.1, TLS 1.2, verified) used by `SystemOnTptp` POSTs.
- `AtpClient.SystemOnTptp.Provers` (Agent caching the SystemOnTPTP prover list) — started only when `config :atp_client, :sotptp, auto_refresh: true` (the default).

The Isabelle, StarExec, and LocalExec backends are stateless from the supervisor's point of view; sessions (`AtpClient.Isabelle.Session`, `AtpClient.StarExec.Session`) are owned by the caller. The Isabelle session indirects through a private `AtpClient.Isabelle.SessionOwner` GenServer that holds the link to `IsabelleClient.Shared` — non-trapping callers therefore survive a failed `open_session/1` (it returns `{:error, reason}` rather than killing them) and a later Shared crash, and the owner monitors the caller so dropping the handle shuts the remote session down cleanly. Always pair `open_session/1` with `close_session/1` (or use the `query*` wrappers, which do this in an `after` block).

## Backend specifics worth knowing

- **Isabelle filesystem coupling.** The Isabelle server cannot accept theory text over the wire; `prove_theory/4` writes `<local_dir>/<name>.thy` and tells Isabelle to load it from `master_dir = isabelle_dir`. `local_dir` (BEAM-side path) and `isabelle_dir` (path as the Isabelle server sees it) differ in containerised or Cygwin setups; `isabelle_dir` defaults to `local_dir` when unset. The `{:isabelle_failed, …, hints}` shape from `prove_theory/4` carries both paths back when "Cannot load theory file" appears.
- **TPTP → Isabelle.** `Isabelle.query/2` / `prove_tptp/3` route TPTP/THF problems through `IsabelleClient.TPTP.isabellize_theory/1` and prepend `unbundle from_TPTP`. The bundled `TPTP.thy` is copied into `:local_dir` on first use. Every Isabelle proving call returns a `Result` whose `evidence` is `{:backend, AtpClient.Isabelle}`: `prove_theory/4` carries the `use_theories` payload in `details.payload`; the per-lemma calls (`prove_lemmas/4`, `query_lemmas/3`, `prove_tptp/3`, `query/2`) put `[%{name, status}]` in `details.lemmas` and fold them weakest-link into `status` — `:theorem` only if every lemma was discharged, `:gave_up` for an empty list. Line numbers are not exposed; they would refer to the generated theory. The classifier over Isabelle's messages is `AtpClient.Isabelle.Verdict`.
- **StarExec auth quirk.** Tomcat's `FormAuthenticator` returns 408 if `j_security_check` is POSTed outside the protected area. `StarExec.login/1` first GETs `/starexec/secure/index.jsp` to obtain a JSESSIONID, then POSTs to `/starexec/secure/j_security_check` — both paths are configurable, but the defaults are deliberate.
- **LocalExec timeouts.** Two timeouts both fold into `{:ok, :timeout}`: the prover-side CPU limit (encoded in `:args` per prover, e.g. E's `--cpu-limit`) and a BEAM-side `Task.shutdown/2` wall-clock kill. `:wall_timeout_ms` defaults to `(cpu_timeout_s + 10) * 1000`. `LocalExec` does **not** inject a `--cpu-limit` flag — each prover's spelling lives in `:args`. The placeholder `"{{problem}}"` in `:args` is substituted with the temp file path; absent that, the path is appended last.
- **Reading output.** `AtpClient.Verdict.interpret/3` reads an SZS status line through `Tptp.Szs.status/1` (last line wins; `#`/`%`, StarExec's elapsed-time prefix and a missing `for <problem>` are all accepted since tptp 0.1.3), then SystemOnTPTP's `<system> says <Value>` summary, then the prover-specific pattern table for systems that print no SZS line (Alt-Ergo, E, LEO-II, SPASS, Vampire, Waldmeister). New prover oddities go in `@patterns` in `lib/atp_client/verdict.ex`. The LocalExec wall-clock kill appends `Tptp.Szs.status_line(:timeout, nil, "wall-clock kill by AtpClient.LocalExec")` to whatever the prover printed, so it reads like any other Timeout.

## Analyzers

`AtpClient.Analyzer.Tptp4x` implements `Tptp.Analyzer` (`id: :tptp4x`, `dialects: :any`): it posts the analysed source to TPTP4X on the configured SystemOnTPTP deployment and turns its `ERROR: Line N Char M …` lines into `Tptp.Diagnostic`s (code `"TPTP4X"`, offsets via `Tptp.Span.offset/3`). `analyze/2` returns `[]` when the deployment is unreachable; `check/2` returns the `{:error, reason}`. The local pass is `Tptp.Lint` via `Tptp.analyze/2`; the "skip the remote pass when the local pass has errors" rule is editor policy and lives in the caller (`Tptp.Diagnostic.any_errors?/1`).
