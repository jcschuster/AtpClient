# Changelog

All notable changes to AtpClient are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-06-26

### Added

- **`AtpClient.LocalExec` backend.** Invokes a locally installed,
  TPTP-compliant prover binary (E, Vampire, …) via `System.cmd/3` and
  normalizes its stdout through the existing SZS classifier. Two-layered
  timeout: the prover-side CPU limit (passed via `:args`) lets provers
  emit a clean `SZS status Timeout`, and an independent BEAM-side
  wall-clock timeout (`:wall_timeout_ms`) kills wedged processes. Both
  paths fold into the same `{:ok, :timeout}` result so callers do not have
  to branch on the failure mode. Binary resolution goes through
  `System.find_executable/1`; missing binaries surface
  `{:error, {:prover_not_found, name}}` rather than raising.
- **`AtpClient.Backend` behaviour** so a UI (Smart Cell, Livebook, …) can
  enumerate and drive backends without hard-coding per-backend knowledge.
  Every backend (`SystemOnTptp`, `StarExec`, `Isabelle`, `LocalExec`) now
  implements `config_key/0`, `label/0`, `config_schema/0`, `verify/1`, and
  `query/2`. The new `query/2` is the cross-backend entry point: it takes
  a TPTP-format problem string plus a keyword list and returns a single
  `atp_result()`, hiding session login/logout, prover selection, theory
  bookkeeping, etc. Per-backend low-level entry points
  (`query_system/3`, `prove_theory/4`, `create_job/3`, `query_tptp/2`, …)
  remain available for callers that need sessions, multi-system fan-out,
  or per-lemma detail.
- **`AtpClient.Config.Field` struct** carrying the UI metadata each
  backend exposes via `config_schema/0`: logical `:type` (`:string |
  :integer | :boolean | :string_list`), layout `:group` (`:connection |
  :defaults | :advanced`), `:required?`, `:secret?`, `:default`, `:label`,
  and `:doc`. The library performs no coercion; values flow into
  `Application.put_env/3` and the per-call opts as-is.
- **`AtpClient.backends/0`** returns the list of behaviour-implementing
  backend modules so a UI can discover them without hard-coding.
- **TPTP-shaped entry points on `AtpClient.Isabelle`.**
  `query_tptp/2` and `prove_tptp/3` accept a TPTP/THF problem string,
  route it through `IsabelleClient.TPTP.isabellize_theory/1`, append the
  configured `:proof_method` (default `"by auto"`) to each generated
  `lemma`, and submit the resulting theory to Isabelle with
  `imports "TPTP"` and `unbundle from_TPTP` active. The bundled `TPTP.thy`
  support theory is copied into `:local_dir` on first use so Isabelle's
  loader can resolve the import. Lemma names carry over from TPTP formula
  names. Pass `proof_method: "by metis"`, `"sledgehammer"`, etc. for
  stronger or probing tactics. Smart-cell consumers can now drive Isabelle
  from the same TPTP editor they use for the SystemOnTPTP / StarExec /
  LocalExec backends; theory-text entry points (`prove_theory/4`,
  `prove_lemmas/4`, `query/3`, `query_lemmas/3`) remain unchanged.
- **`AtpClient.Isabelle.SessionOwner`** — a private GenServer that owns
  the link to `IsabelleClient.Shared`. `open_session/1` now returns
  `{:error, reason}` on a failed connection without killing
  non-trapping callers, a later Shared crash surfaces through a monitor
  rather than an `:EXIT`, and dropping the caller monitors the owner to a
  clean shutdown so server-side Isabelle sessions are no longer orphaned.
  The `Session` struct gains an opaque `:owner` field; treat it as
  internal.
- **`scripts/build_eprover.sh`** — builds the E theorem prover from source
  and installs it to `priv/bin/eprover` for use as the `:local_exec`
  backend's binary.
- **`AtpClient.ResultNormalization.failure_t/0` gains
  `{:prover_not_found, String.t()}`** for the `LocalExec` binary-resolution
  failure mode.

### Changed

- **Library defaults are merged per-key inside `AtpClient.Config.get/2`**
  instead of being seeded via `mix.exs`'s `:env` block. The previous
  arrangement let any `config :atp_client, :<backend>, …` in user
  `config.exs` silently replace the whole keyword list (the OTP
  `Application.put_env/3` semantics), dropping defaults the user had not
  explicitly re-set — most visibly causing a fresh install with partial
  SystemOnTPTP config to fail with `{:unrecognized_output, ""}` because
  `:url` had vanished. Defaults now live in `AtpClient.Config`'s
  `@defaults` (exposed via `Config.defaults/0`) and are merged underneath
  Application env on every read, so a partial user config only overrides
  the keys it actually names. No call-site changes required.
- **`AtpClient.SystemOnTptp.list_provers/0` blocks on the first call**
  until the startup refresh completes or `:sotptp, :refresh_timeout_ms`
  (default 15 s) elapses; subsequent calls return the cached list
  immediately. On timeout it returns `[]` rather than raising. Previously
  it could return `[]` immediately after application start, which the
  caller had no way to distinguish from "the SystemOnTPTP deployment is
  empty."
- **`per_lemma_results/2` now applies `check_tool_signals` per source line.**
  Sledgehammer's `"found a proof"` and Nitpick's `"found a counterexample"`/
  `"found a model"` verdicts surface as `{:ok, :thm}` / `{:ok, :csat}` /
  `{:ok, :sat}` on the per-lemma path, matching `interpret_isabelle_result/1`.
  Previously only Isabelle's `"theorem name:"` completion notification was
  recognised, so probe-style proofs (`sledgehammer nitpick oops`) collapsed
  to `:gave_up`. `{:ok, :timeout}` and `{:ok, :out_of_resources}` are now
  surfaced per lemma too. Lemma names attach to results derived from
  `theorem name:` completions; sledgehammer/nitpick verdicts carry
  `name: nil` because the underlying messages do not name the lemma.
- **`:isabelle_elixir` is now pinned to its GitHub `main` branch**
  (previously `~> 0.3` from Hex). The new TPTP entry points rely on the
  `IsabelleClient.TPTP` module, which is not in the 0.3.0 Hex release.
  Re-pin to a Hex constraint once a release containing `IsabelleClient.TPTP`
  ships.

### Breaking

- **`AtpClient.Isabelle.query/3` no longer defaults its `opts`
  argument.** Pass `[]` explicitly if you have no options to set. The
  default was removed so the three-arity `query/3` (theory text + name)
  does not collide with the `Backend` behaviour's `query/2` (TPTP problem
  string + opts), both of which now live on the same module.
- **`AtpClient.Isabelle.Session` gained an enforced `:owner` field.**
  Anyone constructing `%Session{client: …, config: …}` outside the
  library must now also pass `:owner` (the pid of an
  `AtpClient.Isabelle.SessionOwner`). Treat `Session` as opaque and
  construct it only via `open_session/1`.

### Migration notes

- If you call `Isabelle.query(theory, name)`, change it to
  `Isabelle.query(theory, name, [])`.
- If you read the `:env` block of `AtpClient.MixProject` to discover
  library defaults, call `AtpClient.Config.defaults/0` instead. The
  `:env` block has been removed since the defaults are no longer
  load-bearing there.
- If you construct `%AtpClient.Isabelle.Session{}` directly, stop —
  use `open_session/1` so the `:owner` pid is set up correctly.

## [0.2.0]

### Changed

- **Bumped `:isabelle_elixir` to `~> 0.2`.** The upstream library has moved to a
  task-based wire model; `AtpClient.Isabelle` has been rewritten on top of the
  new `IsabelleClient` (the stateful struct client) instead of
  `IsabelleClientMini`'s polling API. End users of the high-level functions
  (`open_session/1`, `prove_theory/4`, `query/3`, `close_session/1`) see the
  same surface — only the internals and a few error / raw-result shapes have
  changed.
- `AtpClient.Isabelle.Session` now wraps an `%IsabelleClient{}` rather than
  carrying `:socket` and `:session_id` directly. Code that pattern-matched
  `%Session{socket: socket, session_id: id}` must instead use
  `%Session{client: %IsabelleClient{socket: socket, session_id: id}}`.
- `:raw` mode of `prove_theory/4` and `query/3` now returns the `use_theories`
  result map directly (with top-level `"ok"`, `"errors"`, `"nodes"` keys)
  instead of the previous keyword list of poll messages.
  `AtpClient.ResultNormalization.extract_isabelle_text/1` already accepted this
  map shape, so call sites that used it continue to work unchanged.
- `AtpClient.ResultNormalization.interpret_isabelle_status/1` has been
  **renamed** to `interpret_isabelle_result/1` and now takes the `use_theories`
  result map directly. The keyword-list input form is no longer supported — the
  previous name and shape were leaks of the old polling abstraction.
- `AtpClient.ResultNormalization.extract_isabelle_text/1` no longer accepts a
  keyword list; only the result map is supported.
- `{:error, {:isabelle_failed, payload, status}}` errors now carry `payload`
  (the FAILED body) and `notes` (intermediate `NOTE` payloads accumulated by
  `IsabelleClient.Task`) instead of the old full poll-message keyword list. The
  "Cannot load theory file" annotation path continues to emit a 3-tuple
  `{:isabelle_failed, payload, [hint:, local_dir:, isabelle_dir:]}` as before.

### Removed

- The `:poll_interval_ms` Isabelle config setting is no longer used — the new
  client uses blocking `await_task` semantics rather than polling. Existing
  `config :atp_client, :isabelle, poll_interval_ms: ...` entries are removed.

### Migration notes

For most callers the upgrade is a no-op beyond updating `mix.exs`. Action is
only needed if you:

- Pattern-match on `AtpClient.Isabelle.Session` fields directly. Use
  `session.client.socket` / `session.client.session_id` instead, or treat
  `Session` as opaque.
- Call `AtpClient.ResultNormalization.interpret_isabelle_status/1`. Rename to
  `interpret_isabelle_result/1` and pass the `use_theories` payload map (or
  `task.result` of a finished `IsabelleClient.Task`) instead of the previous
  poll keyword list.
- Use `prove_theory(..., raw: true)` or `query(..., raw: true)` and consume the
  result with anything other than `extract_isabelle_text/1`. The shape is now a
  plain map; expect `payload["nodes"]`, `payload["ok"]`, etc.
- Match on the third element of `{:error, {:isabelle_failed, _, _}}` errors. It
  is now either a list of NOTE payload maps (plain failures) or a
  `[hint:, local_dir:, isabelle_dir:]` keyword list (annotated "Cannot load
  theory file" failures).

## [0.1.3]

Prior versions are not retroactively documented here. See git history for
changes before 0.2.0.
