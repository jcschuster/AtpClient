# Changelog

All notable changes to AtpClient are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- **`scripts/build_eprover.sh`** — builds the E theorem prover from source
  and installs it to `priv/bin/eprover` for use as the `:local_exec`
  backend's binary.
- **`AtpClient.ResultNormalization.failure_t/0` gains
  `{:prover_not_found, String.t()}`** for the `LocalExec` binary-resolution
  failure mode.

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
