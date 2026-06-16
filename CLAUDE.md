# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`atp_client` is an Elixir library exposing a single, normalized interface to four backends for automated theorem provers:

- **`AtpClient.SystemOnTptp`** — public `tptp.org` HTTP form API.
- **`AtpClient.StarExec`** — self-hosted StarExec (Tomcat) instances, driven through the same URLs the web UI uses.
- **`AtpClient.Isabelle`** — `isabelle server` over the `:isabelle_elixir` package.
- **`AtpClient.LocalExec`** — locally installed TPTP-compliant binary (E, Vampire, …) invoked via `System.cmd/3`.

All backends collapse their results into `AtpClient.ResultNormalization.atp_result()` — a `{:ok, success}` / `{:error, failure}` tuple with a fixed vocabulary (`:thm`, `:csat`, `:timeout`, `:gave_up`, …). Anything backend-specific that surfaces to callers (Isabelle's `{:isabelle_failed, …}`, LocalExec's `{:prover_not_found, …}`) is documented in the respective module's `@type result`.

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

The Isabelle, StarExec, and LocalExec backends are stateless from the supervisor's point of view; sessions (`AtpClient.Isabelle.Session`, `AtpClient.StarExec.Session`) are owned by the caller. The Isabelle session wraps an `IsabelleClient.Shared` GenServer that owns the TCP socket — always pair `open_session/1` with `close_session/1` (or use the `query*` wrappers, which do this in an `after` block).

## Backend specifics worth knowing

- **Isabelle filesystem coupling.** The Isabelle server cannot accept theory text over the wire; `prove_theory/4` writes `<local_dir>/<name>.thy` and tells Isabelle to load it from `master_dir = isabelle_dir`. `local_dir` (BEAM-side path) and `isabelle_dir` (path as the Isabelle server sees it) differ in containerised or Cygwin setups; `isabelle_dir` defaults to `local_dir` when unset. The `{:isabelle_failed, …, hints}` shape from `prove_theory/4` carries both paths back when "Cannot load theory file" appears.
- **TPTP → Isabelle.** `Isabelle.query_tptp/2` / `prove_tptp/3` route TPTP/THF problems through `IsabelleClient.TPTP.isabellize_theory/1` and prepend `unbundle from_TPTP`. The bundled `TPTP.thy` is copied into `:local_dir` on first use. Lemma `:line` numbers in the response refer to the **generated** theory, not the input TPTP — UIs should attribute by `:name` (which is propagated from the TPTP formula name).
- **StarExec auth quirk.** Tomcat's `FormAuthenticator` returns 408 if `j_security_check` is POSTed outside the protected area. `StarExec.login/1` first GETs `/starexec/secure/index.jsp` to obtain a JSESSIONID, then POSTs to `/starexec/secure/j_security_check` — both paths are configurable, but the defaults are deliberate.
- **LocalExec timeouts.** Two timeouts both fold into `{:ok, :timeout}`: the prover-side CPU limit (encoded in `:args` per prover, e.g. E's `--cpu-limit`) and a BEAM-side `Task.shutdown/2` wall-clock kill. `:wall_timeout_ms` defaults to `(cpu_timeout_s + 10) * 1000`. `LocalExec` does **not** inject a `--cpu-limit` flag — each prover's spelling lives in `:args`. The placeholder `"{{problem}}"` in `:args` is substituted with the temp file path; absent that, the path is appended last.
- **Result normalization.** `ResultNormalization.interpret_result/1` matches the SZS Ontology first, then a list of prover-specific strings for solvers that deviate (Alt-Ergo, SPASS, Vampire, …). New prover oddities go in `@prover_specific_results` in `lib/atp_client/result_normalization.ex`. Isabelle has its own `interpret_isabelle_result/1` and `per_lemma_results/2`.

## Lint subsystem (`AtpClient.Lint`)

Editor-grade syntax/type diagnostics for TPTP input, designed to be called on every debounced keystroke from `KinoAtpClient`. Two backends:

- `AtpClient.Lint.Local` — in-process structural pass, also extracts symbol declarations.
- `AtpClient.Lint.Tptp4x` — delegates to TPTP4X on the configured SystemOnTPTP deployment.

`Lint.analyze/2` runs both by default but **suppresses the remote pass when the local pass found any `:error`** — the user will fix the obvious thing first, and a failing TPTP4X result on top adds noise. Warnings do not suppress. Network failures from the remote pass are swallowed (returned as `[]`) so they never reach the editor's marker gutter.
