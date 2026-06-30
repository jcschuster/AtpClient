# Changelog

All notable changes to AtpClient are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-06-30

### Changed

- **`AtpClient.ResultNormalization.atp_result()` now surfaces the full SZS
  Ontology.** `{:ok, status}` carries the SZS verdict as a downcased atom
  rather than one of six collapsed atoms that lost information. The
  recognised vocabulary covers every Success and NoSuccess atom a
  sledgehammer-targeted prover (or a contemporary TPTP-compliant
  deployment) is likely to emit:

      Success:    :theorem, :unsatisfiable, :satisfiable, :counter_satisfiable,
                  :contradictory_axioms, :equivalent, :counter_equivalent,
                  :counter_theorem, :equivalent_counter_theorem, :equi_satisfiable,
                  :tautology, :tautologous_conclusion, :weaker_conclusion,
                  :no_consequence
      NoSuccess:  :gave_up, :unknown, :incomplete, :timeout, :resource_out,
                  :memory_out, :forced, :user, :inappropriate, :error, :input_error

  The most consequential distinctions the previous shape collapsed are
  `:theorem` ("conjecture follows from the axioms", e.g. Isabelle and
  model-checker endorsement) vs `:unsatisfiable` ("the negated-conjecture
  clause set has no model", e.g. TPTP refutation provers), and
  `:satisfiable` ("a model of the premises was found") vs
  `:counter_satisfiable` ("a model of the negated conjecture was found").
  See <https://tptp.org/Seminars/SZSOntologies/Summary.html> for the full
  ontology.
- **Prover-specific patterns are reclassified to honest SZS atoms** rather
  than sledgehammer's negated-conjecture reading. SPASS "Completion found"
  becomes `:satisfiable` (was `:gave_up`); iProver "CNFRefutation" becomes
  `:unsatisfiable` (was `:theorem`); Vampire "Satisfiability detected" and
  "Termination reason: Satisfiable" become `:satisfiable` (were `:csat`);
  Alt-Ergo "Unknown" becomes `:unknown` (was `:gave_up`); Vampire SIGINT
  becomes `:forced` (was `:interrupted`). Callers running a
  negated-conjecture refutation pipeline should treat `:satisfiable` from
  these provers as a counter-model to the original goal.
- **SPASS / Waldmeister input-rejection patterns move from
  `{:error, :malformed_input}` to `{:ok, :input_error}`.** SPASS "Undefined
  symbol", "Free Variable", "No formulae and clauses found in input file",
  and Waldmeister "Unexpected end of file" are the prover's own SZS
  InputError verdict — the prover ran, read the input, and rejected it.
  SPASS "Please report this error" and Waldmeister "Unrecoverable
  Segmentation Fault" remain `{:error, :internal_error}` because those are
  prover crashes, not verdicts. The SZS `Inappropriate` status likewise
  moved from `{:error, :malformed_input}` to `{:ok, :inappropriate}`.
- **`req` bumped to `~> 0.6`.** Resolves `GHSA-655f-mp8p-96gv`
  (decompression-bomb DoS via auto-decoded archive / compressed response
  bodies, HIGH) and `GHSA-px9f-whj3-246m` (multipart form-data header
  injection, LOW). No API changes at the AtpClient surface.

### Added

- **`t:szs_status/0`, `t:szs_success/0`, `t:szs_no_success/0`** typespecs
  on `AtpClient.ResultNormalization` enumerate the SZS atoms recognised
  explicitly. `szs_status` widens to `atom()` to admit the permissive
  fallback below.
- **Permissive SZS fallback.** Any unrecognised
  `% SZS status <CamelCase>` (or `… says <CamelCase>`) line passes through
  as its snake_case atom — so SZS additions like `EquivalentTheorem`
  become `{:ok, :equivalent_theorem}` without a code change. Bounded
  length and strict CamelCase keep the atom table safe against pathological
  input.
- **Word-boundary SZS line extraction.** Replaces substring matching, so
  longer names no longer collapse onto shorter prefixes:
  `EquivalentTheorem` ≠ `Equivalent`, `CounterSatisfiable` ≠ `Satisfiable`,
  `InputError` ≠ `Error`.

### Breaking

- The collapsed `t:success_t/0` atoms (`:thm`, `:csat`, `:sat`,
  `:out_of_resources`, `:interrupted`) are gone from
  `AtpClient.ResultNormalization.atp_result()` and from
  `AtpClient.Isabelle` (which produced `:thm` / `:csat` / `:sat` /
  `:timeout` / `:out_of_resources` / `:gave_up` from the Isabelle message
  scanner). Pattern matches must be rewritten — see the migration notes.
- The `{:error, :malformed_input}` failure path is gone. SPASS /
  Waldmeister input-rejection patterns and the SZS `Inappropriate` status
  surface in the `{:ok, _}` channel as `:input_error` / `:inappropriate`
  respectively. `failure_t()` no longer lists `:malformed_input`.

### Migration notes

A given old atom can map to one of several SZS atoms depending on which
prover family produced the result. Match the disjunction to preserve
coverage:

- `:thm` → `:theorem` (Isabelle / Sledgehammer / Alt-Ergo Valid) **or**
  `:unsatisfiable` (TPTP refutation provers, iProver CNFRefutation).
- `:csat` → `:counter_satisfiable` (SZS CounterSatisfiable, Isabelle /
  Nitpick counter-example) **or** `:satisfiable` (SZS Satisfiable,
  Isabelle / Nitpick model, Vampire "Satisfiability detected", SPASS
  "Completion found").
- `:sat` → `:satisfiable` (only emitted by the Isabelle classifier for
  Nitpick / Quickcheck models).
- `:out_of_resources` → `:resource_out` (SZS ResourceOut, SPASS / Waldmeister
  resource patterns) **or** `:memory_out` (SZS MemoryOut, Isabelle "Out of
  memory").
- `:interrupted` → `:forced` (SZS Forced, Vampire SIGINT) **or** `:user`
  (SZS User).
- `:gave_up` against an Alt-Ergo verdict → `:unknown`; against SZS
  `Incomplete` → `:incomplete`; otherwise still `:gave_up`.
- `{:error, :malformed_input}` → match `{:ok, :input_error}` instead.

So a previously written TPTP triage like

```elixir
case AtpClient.SystemOnTptp.query(problem, default_system: "cvc5---1.3.0") do
  {:ok, :thm}                       -> :proved
  {:ok, :csat}                      -> :disproved
  {:ok, atom} when atom in [:timeout, :out_of_resources, :gave_up, :interrupted]
                                    -> :inconclusive
  {:error, :malformed_input}        -> :bad_input
  {:error, _}                       -> :error
end
```

becomes

```elixir
case AtpClient.SystemOnTptp.query(problem, default_system: "cvc5---1.3.0") do
  {:ok, status} when status in [:theorem, :unsatisfiable]
                                    -> :proved
  {:ok, status} when status in [:satisfiable, :counter_satisfiable]
                                    -> :disproved
  {:ok, status} when status in [:timeout, :resource_out, :memory_out,
                                :gave_up, :unknown, :incomplete,
                                :forced, :user, :inappropriate]
                                    -> :inconclusive
  {:ok, :input_error}               -> :bad_input
  {:error, _}                       -> :error
end
```

## [0.4.0] - 2026-06-29

### Changed

- **`AtpClient.ResultNormalization.per_lemma_results/2` becomes `/3`** and
  now takes `(payload, lemma_specs, opts)` instead of `(payload, opts)`. The
  caller supplies one `%{name: String.t(), range: Range.t()}` spec per
  lemma (`AtpClient.Isabelle.lemma_specs/1` builds these from the theory
  body) and the classifier buckets messages by body-line range rather than
  re-deriving structure from `pos.line` alone. Returned `lemma_result()`
  maps lose the `:line` field — line numbers referred to the generated
  theory file, not the caller's source, and were ambiguous when a bucket
  contained multiple messages.
- **Per-lemma classifier no longer scans concatenated text across
  messages.** Each message is classified individually before the bucket is
  reconciled. This fixes two regressions visible with multi-lemma Isabelle
  jobs: (a) `Nitpick found a model` + `Nitpick found no counterexample`
  surfaced as `:csat` because the `"Nitpick found a" + "counterexample"`
  substring test fired across the message join, and (b) `by <tactic>`
  failing on a False goal was reported as `:thm` because Isabelle echoes
  `theorem name: <goal>` at the `by` position alongside the
  `Failed to finish proof` error. Verdict precedence is documented on
  `per_lemma_results/3`.
- **`per_lemma_results/3` accepts `:file`** to drop messages whose
  `pos.file` does not end with a given suffix. `prove_lemmas/4` uses this
  to filter out noise from the bundled `TPTP.thy` and other transitively
  imported theories that previously produced phantom lemma rows.
- **Lemma names always come through** on the per-lemma path — the name
  comes from the body (via `lemma_specs/1`), not from parsing `theorem
  name:` out of Isabelle messages. Sledgehammer / Nitpick verdicts no
  longer surface as `name: nil`.

### Added

- **`AtpClient.Isabelle.lemma_specs/1`** — extracts `[%{name, range}]` from
  a theory body. Used internally by `prove_lemmas/4` and `prove_tptp/3`;
  exposed for callers that want to pre-compute specs.

### Migration notes

- If you call `ResultNormalization.per_lemma_results(payload)` or
  `per_lemma_results(payload, line_offset: n)`, switch to
  `per_lemma_results(payload, specs, opts)` where `specs` come from
  `AtpClient.Isabelle.lemma_specs(body)`. The high-level
  `prove_lemmas/4` / `prove_tptp/3` / `query_tptp/2` entry points already
  do this for you.
- Drop reads of the `:line` field on `lemma_result` entries. Attribute by
  `:name` instead — line numbers were a generated-theory leak and have
  been removed from the returned shape.

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
