# Roadmap: PAAR'26 "Elixir meets TPTP" → Camera-Ready

This document maps reviewer comments to concrete revision tasks, in the order
they should be tackled. Phases are ordered by dependency: textual fixes and
code-shipping prerequisites land first; the StarExec validation effort is the
long pole; strategic framing follows once validation outcomes are known.

Two structural changes since the previous revision of this roadmap:

1. **The local solver backend has moved off the stretch list and onto the
   critical path**, ahead of StarExec. It is small and fully under our
   control, and building it first installs a known-good TPTP prover and
   exercises the SZS classifier against *real* prover output — both of which
   then serve as the oracle and test fixtures for StarExec validation. The
   ordering that looks backwards (former stretch goal before the mandatory
   one) is the de-risking move.
2. **A collaboration track for David Fuenmayor** (`isabelle_elixir` author)
   has been added. He offered to help, and his library's v0.3.0 release
   includes capabilities we depend on. Work that lives on his side of the
   library boundary is delegated to him; see the dedicated section below.

## Triage summary

| Reviewer | Verdict | Blocking issues |
|---|---|---|
| 16A | Weak accept | Figure 1 `oops`/`:thm` inconsistency; depth-of-contribution concern |
| 16B | Accept | 8 specific issues, all with concrete fixes (see Phase 0–3) |
| 16C | Weak accept *conditional on StarExec testing before the conference* | StarExec validation |

The 16C condition makes Phase 2 (StarExec validation) effectively mandatory.

---

## Phase 0 — Textual fixes (no code work)

These can land first; they unblock nothing but clear the desk.

- **Figure 1 / `:sat` / Isabelle semantics.** See the dedicated section
  "Review #16A: architectural vs. communicative" below. Short version: keep
  the current cross-backend semantics (`:thm` = "oracle reported success"),
  document this explicitly in §3, and change the figure example to `by auto`
  for pedagogical cleanliness.
- **Promote footnote 6 to a real explanation (16B).** A sentence or two in
  §3: SZS distinguishes `Satisfiable` only for formulas (where it implies
  the *negation* is countersatisfiable), but `nitpick[satisfy]` models the
  formula itself as a positive existence claim. Note explicitly that this
  affects only the Isabelle backend; SystemOnTPTP results map
  `Satisfiable → :csat` per Table 1.
- **`\Cref` capitalization (16C).** Either use `\Cref` at sentence-initial
  positions or configure `cleveref` to always capitalize.
- **Figure 2 caption (16B).** Add OS and browser to the screenshot caption.
- **Quantify SZS fallback coverage (16B).** One sentence in §3 with the
  numbers already implicit in `result_normalization.ex`: N
  prover-specific patterns covering M provers (Alt-Ergo, E, SPASS, Vampire,
  Waldmeister).
- **Reconcile §1 and §7 on StarExec (16B).** Currently §1 lists StarExec as
  a contribution while §7 calls it an unvalidated prototype. After Phase 2
  lands, §7 changes to a validation report and the contradiction dissolves.

---

## Phase 1 — Code-shipping prerequisites

Reviewer 16B caught two real bugs. These need to ship in a Hex release before
§3/§4 can credibly claim the fixed behavior.

- **Auto-load default config at app start (16B).** Today the default
  SystemOnTPTP URL sits in `mix.exs` but isn't pulled into
  `Application.get_env/2`, so a fresh install silently returns
  `{:unrecognized_output, ""}`. Fix in `application.ex` — set defaults via
  `Application.put_env/3` on startup if not already configured. Bump patch
  version, push to Hex, note in `CHANGELOG.md`.
- ✅ **`list_provers/0` race fixed.** `Provers.get_systems_list/0` now
  blocks on the first call until the startup refresh completes or
  `:sotptp, :refresh_timeout_ms` (default 15 s) elapses; subsequent calls
  return the cached list immediately. On timeout it returns `[]` rather
  than raising, so the failure mode is the same as a configured-but-down
  deployment. No README/footnote workaround needed.
- **Reconcile the `isabelle_elixir` dependency constraint.** The paper and
  prior notes reference `~> 1.0`, but the live library is at v0.3.x
  (`IsabelleClient`, `Server`, `Result`, with `Shared`/`Raw` variants). This
  mismatch must be resolved before camera-ready regardless of the
  collaboration track: bump the constraint to `~> 0.3`, adapt `isabelle.ex`
  to any API drift, re-run Credo/Dialyzer/tests, update `CHANGELOG.md`. This
  is *our* release work, not delegated. Coordinate the pin with David so the
  positional-diagnostics API (see collaboration section) is stable at the
  version we depend on.

Both 16B fixes need to be in a released version before the paper can describe
the fixed behavior.

---

## Phase 2 — Local solver backend (`AtpClient.LocalExec`) ✅ shipped

**Promoted from the former Phase 4 stretch list.** Build this *first* among
the code-heavy work. It is the smallest fully-controlled piece, and it
de-risks Phase 3 (StarExec): once a real prover is installed and producing
known-good SZS output locally, those outputs become the oracle and the
offline test fixtures for the StarExec validation, and any divergence there is
immediately attributable to *transport* rather than *prover* behavior.

### What landed

- `AtpClient.LocalExec` in `lib/atp_client/local_exec.ex` with `query/2` and
  `resolve_binary/1`. Two-layered timeout as designed: prover-side CPU limit
  via `:args`, BEAM-side wall-clock kill via `Task.yield`/`Task.shutdown`.
  Both timeout paths fold into the same `{:ok, :timeout}` result; callers
  see a single, uniform success-type for "the deadline was hit," regardless
  of which side of the boundary noticed first.
- `:local_exec` config defaults in `mix.exs` (`binary`, `args`,
  `cpu_timeout_s`, `wall_timeout_ms`) and added to `AtpClient.Config`'s
  `backend()` type.
- `AtpClient.ResultNormalization.failure_t/0` extended with
  `{:prover_not_found, String.t()}` so the binary-resolution failure mode
  has a typed home.
- 14 offline tests in `test/atp_client/local_exec_test.exs` driven by a
  fake-`sh`-script "prover" (canned SZS output, optional sleep, configurable
  exit code). Covers: SZS classification across happy paths, binary
  resolution, wall-clock kill, default-derivation of `:wall_timeout_ms`,
  argument construction with append-vs.-`{{problem}}`-placeholder.
- Real-prover smoke test gated behind `@tag :local_prover`, excluded by
  default in `test/test_helper.exs`. CI stays green without a prover
  installed.
- `scripts/build_eprover.sh` — builds the E theorem prover from source at a
  pinned tag and installs `eprover` into `priv/bin/` (which is gitignored)
  for use as the `:local_exec` backend's binary. Tag is `E_TAG`-overridable.
- Top-level `AtpClient` module doc and `mix.exs` doc grouping updated to
  list four backends. `CHANGELOG.md` gains an `[Unreleased]` section
  describing the new backend and failure-type additions.


### Namespace

The repo already has `local.ex` as `AtpClient.Lint.Local`. To avoid collision,
use module `AtpClient.LocalExec` in file `local_exec.ex`. Keep the lint
namespace untouched.

### What it does

Resolve a configured prover binary, shell out with the problem file and a
timeout, capture stdout, and hand it to the existing SZS classifier. The
classifier is why this is cheap: `ResultNormalization.interpret_result/1`
already covers E, Vampire, SPASS, Waldmeister, Alt-Ergo, iProver, LEO-II. The
work is almost entirely the process-management shell around it.

Skeleton:

```elixir
defmodule AtpClient.LocalExec do
  @moduledoc """
  Backend that invokes a locally installed TPTP-compliant prover via
  System.cmd/3. No authentication, no polling — the prover runs to completion
  (or its timeout) and its stdout is normalized through
  AtpClient.ResultNormalization.
  """
  alias AtpClient.{Config, ResultNormalization}

  @spec query(String.t(), keyword()) ::
          ResultNormalization.atp_result() | {:error, term()}
  def query(problem, opts \\ []) when is_binary(problem) do
    bin   = Config.fetch!(:local_exec, :binary, opts)       # e.g. "eprover"
    args  = Config.fetch(:local_exec, :args, [], opts)      # e.g. ["--auto"]
    cpu_s = Config.fetch(:local_exec, :cpu_timeout_s, 60, opts)
    wall_ms = Config.fetch(:local_exec, :wall_timeout_ms, (cpu_s + 10) * 1000, opts)

    with {:ok, path}   <- write_temp(problem),
         {:ok, exe}    <- resolve(bin),
         {:ok, output} <- run(exe, args ++ [path], wall_ms) do
      ResultNormalization.interpret_result(output)
    end
  end

  # resolve/1 → System.find_executable/1, else {:error, {:prover_not_found, bin}}
  # write_temp/1 → Briefly.create/Temp file, cleaned in an after-block
  # run/3 → Task.async wrapping System.cmd(exe, args, stderr_to_stdout: true),
  #         guarded by Task.yield/2 + Task.shutdown/2 for the wall-clock kill
end
```

### Three points that separate "works on my machine" from publishable

1. **Two-layered timeout, and we own both.** The prover's own limit (E's
   `--cpu-limit`, Vampire's `-t`) is authoritative — it lets the prover emit
   `SZS status Timeout` / `ResourceOut`, which the classifier maps cleanly.
   But `System.cmd/3` has no wall-clock kill, so a wedged prover hangs the
   caller. Wrap the call in a `Task` with `Task.yield/2` + `Task.shutdown/2`.
   Both timeout paths fold into the same `{:ok, :timeout}` result so the
   cross-backend `atp_result` contract stays uniform; the *existence* of the
   two-layered enforcement is still worth one sentence in the paper as the
   "messy reality" example 16A asked for.
2. **Binary resolution in config, validated at call time.** Use
   `System.find_executable/1` and return `{:error, {:prover_not_found, bin}}`
   rather than letting `System.cmd/3` raise. Mirror the `ISABELLE_TOOL`
   env-var pattern David uses, and the `:isabelle_dir` discipline already in
   our `isabelle.ex` — the idiom is established; reuse it.
3. **Keep CI offline.** Unit-test argument construction and the timeout-task
   logic with a *fake* binary (a shell script that echoes a canned
   `SZS status Theorem` and optionally sleeps). Gate any real-E / real-Vampire
   test behind `@tag :local_prover`, which CI skips. GitHub Actions stays
   green without a prover installed.

### Reused helper

Design the `run/3` + timeout helper so it can be pointed at `tptp4X` as well as
a prover. The "faster TPTP4X via local invocation" idea (former Phase 4) then
becomes a near-copy feeding the lint's authoritative tier through a Smart Cell
config toggle, rather than a fresh implementation.

### Scope decisions (settled)

- **Single-binary** for the camera-ready. Portfolio/parallel-prover mode
  noted as future work; `LocalExec.query/2` takes a single `:binary`.
- **Folded timeout result.** The two timeout paths (prover-side CPU limit
  vs. BEAM-side wall-clock kill) both surface as `{:ok, :timeout}`. The
  uniform result keeps the cross-backend `atp_result` contract intact —
  callers do not have to branch on which side of the boundary noticed the
  deadline. The distinction is still observable in logs (the wall-clock
  path synthesizes a marker SZS line that names `AtpClient.LocalExec`) for
  debugging, but it is not part of the public result type.

---

## Phase 2.5 — Uniform backend behaviour ✅ shipped

Groundwork for Phase 4's Smart Cell framing, landed off the back of Phase 2
once four backends made the pattern worth naming.

- `AtpClient.Backend` behaviour in `lib/atp_client/backend.ex`. Every backend
  (`SystemOnTptp`, `StarExec`, `Isabelle`, `LocalExec`) now implements
  `config_key/0`, `label/0`, `config_schema/0`, `verify/1`, and `query/2`.
  The Smart Cell can therefore enumerate backends, render their settings,
  probe reachability, and run a TPTP problem without hard-coding per-backend
  knowledge.
- `AtpClient.Config.Field` struct (`lib/atp_client/config/field.ex`) carries
  the UI metadata each backend returns from `config_schema/0`: logical type
  (`:string | :integer | :boolean | :string_list`), grouping
  (`:connection | :defaults | :advanced`), `secret?` for password masking,
  `required?`, `default`, `label`, and `doc`.
- `AtpClient.backends/0` lists the four modules so UIs need only one entry
  point. The behaviour `query/2` lives alongside each backend's existing
  low-level API (`query_system/3`, `query_tptp/2`, `create_job/3`, …); only
  the new arity is part of the cross-backend contract. Isabelle's
  three-arity `query/3` for hand-written theories now takes `opts`
  mandatorily (pass `[]` if none) so it does not collide with the
  behaviour's `query/2`.
- New offline tests in `test/atp_client/backend_test.exs` cover the
  registry, schema shape (field types, group, `secret?` only on strings,
  unique keys, required connection fields per backend), and the failure
  branches of `verify/1` / `query/2` (unreachable host, missing binary).

### Isabelle session robustness ✅ shipped

Adjacent to Phase 2.5: previous Isabelle sessions linked the caller
directly to `IsabelleClient.Shared`, so a failed `start_link` or a later
Shared crash killed any non-trapping caller. Now `open_session/1` runs the
link through a private `AtpClient.Isabelle.SessionOwner` GenServer that:

- Traps the `start_link` failure and returns `{:error, reason}` to the
  caller.
- Translates a Shared crash into a clean `:stop` that the caller can
  observe via a monitor instead of being killed by an `:EXIT`.
- Monitors the caller and shuts the Shared process down on caller death,
  preventing orphaned server-side Isabelle sessions.

The `Session` struct gains an opaque `:owner` pid; `close_session/1` stops
the owner, which in turn closes Shared. `test/atp_client/isabelle_test.exs`
pins the non-trapping-caller guarantee.

---

## Phase 3 — StarExec validation via local container

This is the headline review-response. It turns 16C from "weak accept
conditional on testing" into a clean accept, and lets §1's contribution claim
survive contact with §7. Build it *after* Phase 2 so a known-good local prover
and reference outputs are already in hand.

### Deployment vehicle

The original `StarExec/StarExec` is a heavy Tomcat + MySQL + Ant stack: it
needs Ant to build, a data directory mapped to a matching path on every
compute node, and dedicated sandbox + tomcat users in a `star-web` group —
exactly the manual setup a containerized fork exists to avoid. Realistic
options:

1. **`StarExecMiami/StarExec-ARC`** — the Miami group (Sutcliffe's group, the
   same TPTP/SystemOnTPTP ecosystem we publish into) maintains a
   containerized fork built on Podman + microK8s/EKS, with a
   `starexec-containerised` subdirectory. Cleanest path: actively maintained,
   community-aligned. **Scope caution:** ARC is oriented toward running ATP
   systems *within* StarExec on Kubernetes. For *validation* we do not need
   cluster orchestration — we need one StarExec instance reachable over HTTP
   that the client can log into and submit one job to. Aim for the standalone
   `starexec-containerised` path and resist being pulled into the full
   microK8s bring-up.
2. **Self-built Docker Compose** wrapping upstream `StarExec/StarExec` if ARC
   lifts things we don't need. Tighter scope, more manual work. Last resort.

Start with (1); spend ~half a day before committing. Fall back to (2) only if
blocked.

### Validation procedure

The minimum end-to-end test that earns the "validated" claim:

1. Bring up the container; create an admin user; create a "space" with one
   solver (E or Vampire — both speak TPTP+SZS natively; reuse the binary
   installed for Phase 2) and one trivial benchmark.
2. From `iex`, exercise the full path: `login/1` → `create_job/3` with the
   actual field set the local instance expects → extract `job_id` from the
   redirect → `wait_for_job/3` → `get_pair_stdout/3` →
   `ResultNormalization.interpret_result/1` returning `{:ok, :thm}`.
3. **Do the non-happy-path cases deliberately and early** — a benchmark
   producing `Timeout` and one producing `CounterSatisfiable`. The SZS
   classifier branch is the part reviewers care about and the part most
   likely to expose a real `default_complete?/1` or cookie bug. Because
   Phase 2 already produced known-good `Theorem` / `Timeout` /
   `CounterSatisfiable` output from E or Vampire locally, any divergence here
   is immediately diagnosable as a *transport* bug in `star_exec.ex` rather
   than a prover difference.
4. Capture the exact `create_job` field set that worked, **and** save the real
   job JSON and pair-stdout payloads as test fixtures. Ship
   `examples/starexec_smoke_test.exs` and reference it from the paper; the
   saved payloads give the SZS-interpretation path an *offline* regression
   test even though the live submission cannot run in CI. This preserves the
   offline-CI-vs-live-integration separation.

### Code likely to need touching

`star_exec.ex` was written against documentation, not a live instance. Ordered
by likelihood:

1. **Cookie handling (highest risk).** `extract_cookies/1` flattens all
   `set-cookie` headers into one name-keyed map, and login runs with
   `redirect: false`. Tomcat form auth responds 302 on success, and the
   authoritative session cookie may be set on the *redirect target* rather
   than the `/j_security_check` response. If so, the jar will be missing it
   and every subsequent authenticated request fails. May need to follow the
   post-login redirect once to collect the real cookie. This is the classic
   Tomcat-form-auth gotcha — check it first.
2. **`create_job/3` form encoding.** Currently sends `URI.encode_query`
   (form-urlencoded), but StarExec's add-job handler expects *multipart* in
   some releases, and benchmark/solver selection fields are genuinely
   multipart. Expect to switch to `Req`'s `form_multipart` and to discover
   the real field names empirically from the browser network tab against the
   local instance.
3. **`default_complete?/1` against real JSON.** The two guarded shapes
   (`jobComplete: true`, `completed == totalJobPairs`) are
   documentation-derived. Capture one in-progress and one completed job's
   JSON and adjust so the *default* works out of the box (the `:complete_fun`
   escape hatch means this won't block, but the paper's "works out of the
   box" claim depends on the default).
4. **Job-id extraction.** Currently left to the caller; consider a
   `extract_job_id/1` helper that parses the redirect Location for the common
   case.

### Paper integration

Rewrite §7's "StarExec Validation Status" paragraph along these lines:

> We validated the StarExec backend end-to-end against a self-hosted
> instance deployed via [ARC / Docker Compose], exercising authentication,
> job submission, polling, and SZS-normalized result retrieval against E
> and Vampire on representative TPTP problems. The smoke-test script is
> shipped with the repository.

If validation surfaces a real interop gotcha worth reporting (cookie ordering,
multipart field set, completion-predicate variance across StarExec versions),
promote it from a fix-it-and-move-on into a short paragraph. It materially
strengthens the "we handle the messy reality" framing and helps address 16A's
depth-of-contribution worry.

---

## Phase 4 — Strategic framing & related work

Harder edits — repositioning rather than fixing.

- **Related work expansion (16B).** Add `online-atps` (Prieto), `aztek/atp`,
  and the `tptp` Haskell package to §8 with brief comparison. Honest framing:
  `online-atps` overlaps cleanly with our SystemOnTPTP coverage but is
  single-backend; the Haskell `tptp` packages cover parsing rather than
  service integration. This *strengthens* the paper because it makes "unified
  across three backends + Livebook + agent-ready" the differentiator rather
  than "we talk to SystemOnTPTP." Ensure the genuine comparator for the
  editor tooling is cited correctly: the TPTP Editor VS Code extension by
  Daniel Li and Geoff Sutcliffe (the previously-flagged "LSP-based TPTP modes"
  citation was fabricated and must not reappear).
- **Livebook introduction + honest Jupyter comparison (16B).** §5 assumes the
  reader knows Livebook. Add a paragraph at the top: what Livebook is
  (Elixir-native reactive notebook), what Smart Cells are (live processes with
  custom UI sharing the notebook's BEAM node, not just rendered cells), and an
  honest note on adoption cost (requires installing Elixir). Then clarify
  16B's black-box-GUI question: yes, the Smart Cell is usable without writing
  Elixir for one-off TPTP editing and prover invocation, but composing it into
  a workflow needs Elixir.
- **Response to 16A on contribution depth.** Don't try to defeat 16A
  head-on — the reviewer is correct that a SystemOnTPTP wrapper is a small
  layer in isolation. The reframing 16B already pointed toward is the right
  move: the contribution isn't "we talk to ATPs," it's "we make ATP access a
  first-class citizen of the BEAM agent-infrastructure ecosystem, with unified
  semantics across structurally very different backends, fault-tolerant
  polling, and an interactive front-end." Three Phase 2/3 outcomes turn this
  from a claim into a demonstration: the validated StarExec backend, the local
  solver backend, and the agent-facing MCP server (§9). Tighten the intro and
  §6 to lead with this framing.

---

## Phase 5 — Stretch (only if Phases 0–4 are comfortably done)

- **Richer result fields.** Extending `atp_result` with optional runtime,
  proof-clause count, and prover-specific stats. Bigger API design question
  (struct? map? sibling `atp_meta`?) — probably belongs in future work for the
  paper, not the camera-ready.
- **Multi-theorem Isabelle support.** Contingent on the David collaboration
  track landing cleanly (see below). If the per-lemma example comes back
  stable, promote it; otherwise it is a strong §9 future-work paragraph that
  also credits a collaborator.
- **MCP server promotion.** If Phases 0–3 are comfortably done, extend the
  existing `AtpMcp` server to wrap `LocalExec` (cheap once `LocalExec` exists)
  so it is multi-backend rather than SystemOnTPTP-only. Otherwise it stays a
  scoped §9 demonstration; see "MCP server" below.

---

## Collaboration track — delegating to David Fuenmayor

David authors `isabelle_elixir`, the library our Isabelle backend sits on. His
v0.3.0 (late May 2026) adds two capabilities relevant to us: a THF/TPTP
*notation* bridge (`from_TPTP` / `to_TPTP`, `priv/isabelle/tptp/TPTP.thy`) and
line/offset-aware diagnostics (`IsabelleClient.Result` with positional
`{line, offset, end_offset, file}` data and a filterable `diagnostics/2`).

**Important scoping caveat for the paper.** The THF bridge lets one write
THF-style notation *inside* an Isabelle theory body and pretty-print terms back
in THF style. Per David's own README, it is **not** a parser for annotated
TPTP problem files (`thf(name, role, formula).`). So "TPTP-to-Isabelle parsing"
is true in the notation sense, not the "feed it a `.p` file" sense. Do not
overclaim this in §3 or §8. The genuinely new primitive for us is the
positional diagnostics: they are what could underpin per-line or per-theorem
result attribution. Parsing a multi-formula TPTP file into N separate goals is
work that exists in *neither* library today.

### Delegate to David (his side of the boundary)

- **A stable, documented multi-formula → multi-lemma story.** Ask whether the
  THF bridge can ingest a realistic annotated FOF/THF problem (the Agatha
  example in his livebook is hand-translated, which is the tell). If genuine
  `.p` ingestion is in scope, that parser belongs in `isabelle_elixir`; we
  should be a consumer, not a re-implementer.
- **A pinned, semver-stable contract for the positional diagnostics.** We need
  `Result.Position` offsets and the line-numbering convention (his README
  notes the generated theory header makes snippet line `n` appear as Isabelle
  line `n+1`) to be stable across releases, since per-theorem mapping depends
  on them. Ask him to treat `Result.Position` and the `diagnostics/2` filter
  API as public and stable at the version we pin in Phase 1.
- **A worked multi-lemma example in his `TPTP.livemd`** returning per-lemma
  pass/fail, which we can cite and build on rather than reverse-engineer.
- **Technical review of the §3 Isabelle-semantics paragraph** — the `:thm` =
  oracle-claimed vs. kernel-verified framing (see #16A section). He is the
  right person to sanity-check that we describe Isabelle's guarantees
  correctly.

Framing the contribution this way gives a clean, citable collaborator
contribution and strengthens the "first-class BEAM ecosystem" story without us
taking on his domain.

### Keep on our side

- The dependency-constraint bump and re-integration (Phase 1) — it's our
  release.
- Wiring the positional diagnostics into our result type *if* multi-theorem
  support is judged in scope (Phase 5). Whether to extend `atp_result` for
  per-goal results is our API-design call.
- All paper-framing decisions, including how much to claim about multi-theorem
  support and where it sits (camera-ready feature vs. §9 future work). The
  temptation is to oversell the THF bridge as full TPTP-file parsing; resist
  it, consistent with the honest-scope discipline applied to StarExec.

### Sequencing caution

Multi-theorem support is appealing but **not** a reviewer condition. 16C's
condition is StarExec; Phase 1's bugs gate the release. Scope the David
collaboration as "explore for camera-ready, land in §9 future work if it
doesn't fully cohere in time," and protect the StarExec critical path. If the
per-lemma example returns clean and stable quickly, promote it (Phase 5); if
shaky, it is a strong future-work paragraph that credits a collaborator.

---

## MCP server (`AtpMcp`) — scope as §9 demonstration

The repo contains a working-but-minimal MCP stdio server (`atp_mcp.ex`): a
JSON-RPC 2.0 server over stdin/stdout with the standard
`initialize` / `tools/list` / `tools/call` lifecycle and three tools
(`list_provers`, `run_prover`, `compare_provers`), behaviour-indirected so it
is testable offline. It currently wraps only the SystemOnTPTP backend and
declares MCP protocol revision `2024-11-05`.

**Recommendation: include it, but in §9 as a demonstration of the
architecture's agentic fitness — not in §1 as a validated contribution.** An
MCP server is the literal mechanism by which an LLM agent invokes ATPs; the
fact that it falls out of the architecture in ~90 lines wrapping an existing
behaviour *is* the argument for the "first-class agent-infrastructure citizen"
framing (Phase 4 / #16A). But introducing a second under-tested component as a
headline contribution would undercut the honest-validation discipline held
elsewhere and hand 16C a new "is this actually tested?" target.

Concrete handling:

- Put it in §9 with transparent scope-labelling (the same language used for
  StarExec): a minimal proof-of-concept MCP server wrapping the SystemOnTPTP
  backend, sufficient to show ATP tools composing into an LLM agent loop, with
  single-backend scope noted as a known limitation. One short code block or
  figure showing an agent calling `run_prover` and getting back an SZS status
  is worth more than a paragraph of claims.
- **Fix the protocol version string regardless of prominence.** The current
  stable MCP revision is `2025-11-25`; the declared `2024-11-05` is the
  original revision and reads as inattention to a reviewer who knows MCP.
  Either bump it or footnote that we target the initial revision.
- **Add a forward-looking note tied to the current spec.** The `2025-11-25`
  revision introduced an experimental *Tasks* primitive (call-now /
  fetch-later, returning a task handle for status polling and deferred result
  retrieval). That maps almost exactly onto ATP invocation's long-running,
  poll-for-completion character — the same shape as StarExec's `wait_for_job`
  and the wall-clock-vs-prover-timeout distinction in `LocalExec`. We need not
  implement Tasks for the camera-ready, but one sentence noting the alignment
  shows §9 is tracking where the protocol is going, not just where it was.
- Gate effort behind StarExec validation and the Phase 1 release. If time is
  tight it stays a one-paragraph-plus-figure future-work item, which is enough
  to land the point. Promotion to multi-backend (wrapping `LocalExec`) is a
  Phase 5 item.

---

## Review #16A: architectural vs. communicative

> *"In Figure 1, the Isabelle example calls sledgehammer but then withdraws
> the theorem with an 'oops'. However, the system answers with 'thm', this
> is clearly a problem."*

**Short answer:** this is more architectural than communicative, though
there is a legitimate case for the current behavior.

### The semantic gap

Inside Isabelle's LCF-style framework, "this theorem holds" has a specific
meaning: the kernel has accepted a proof term. When you write
`theorem T by auto` and the theory compiles, you have *that* level of
certainty. When you write `theorem T sledgehammer oops`, you have a
strictly weaker claim: a Sledgehammer call (itself an unverified external
oracle) reported success, but no proof was ever submitted to the kernel,
and the theorem statement was explicitly withdrawn.

The fact that `result_normalization.ex` reaches `{:ok, :thm}` via two
structurally different paths — "Sledgehammer found a proof" vs. "every
theory node's `status.ok` is true" — is exactly the architectural seam
the reviewer is pointing at. Both paths emit the same atom but carry
different epistemic weight, and one of them (the Sledgehammer path)
doesn't even require the goal to have been discharged.

### The defensible counterposition

The "Sledgehammer as probe" workflow is genuine and widely used: people
write `sledgehammer oops` precisely to ask "is this provable, before I
commit to a proof structure?" Supporting that question is valuable, and
reducing it to the prover backend's report (which is all you have
anyway) is defensible. The problem is that the *same* result atom is
also used for kernel-verified proofs, so a caller can't tell which one
they got.

### The cross-backend uniformity argument

This cuts against tightening Isabelle's semantics. For SystemOnTPTP and
StarExec, "a prover said Theorem" is the strongest claim available — no
separate kernel verification step exists. If Isabelle's `:thm` becomes
"kernel-verified," the result type stops being uniform across backends;
Isabelle's `:thm` becomes strictly stronger than SystemOnTPTP's `:thm`.
Defensible (Isabelle *is* stronger), but a real design commitment that
deserves to be named.

### Two coherent stories

1. **`:thm` means "an oracle reported success"** across all backends,
   uniformly. Honest, uniform, weaker. Figure 1 with `oops` is then
   *correct*, but §3 must say so explicitly.
2. **`:thm` means "kernel-verified where applicable, prover-claimed
   elsewhere"** — stronger Isabelle semantics, possibly with a separate
   atom (`:proof_found`?) for the Sledgehammer-probe case. More faithful
   to LCF, more useful for downstream tooling that wants to trust the
   result, breaks strict uniformity.

### Recommendation

Pick **(1)** and own it. It matches what the code actually does, is
honestly defensible, and adding the explicit clarification in §3 directly
answers 16A's objection without an API redesign. Concretely:

- Add to §3, near the introduction of `atp_result`:
  > Across all backends, `:thm` reflects the prover's or tool's claim of
  > success, not kernel verification. For stronger guarantees within
  > Isabelle, use `by`-style proof methods that submit a proof term to
  > the kernel.
- Change Figure 1's Isabelle example to `by auto` (or similar). Not
  because the current example is *wrong* under reading (1), but because
  the pedagogical purpose of Figure 1 is to show the unified API at its
  cleanest; an example where the two semantic readings coincide avoids
  re-litigating this in the reader's head.
- Optionally, add a sentence in §3 or §6 acknowledging the probe-style
  usage:
  > Sledgehammer can also be used as a probe via `sledgehammer oops`;
  > this returns `{:ok, :thm}` on the same grounds, with the caveat that
  > no proof has been checked by Isabelle's kernel.

That turns 16A's catch from "clear problem" into "valid concern,
addressed by explicit semantics" — the better outcome for the paper
because it shows you've thought about exactly the thing the reviewer
was probing.

---

## Suggested ordering

- **Phase 0** textual fixes in parallel with starting **Phase 3** container
  setup (the container brings itself up while you do textual fixes and write
  `LocalExec`).
- **Phase 1** fixes (including the `isabelle_elixir` constraint bump) need to
  land in a Hex release before the paper can cite the fixed behavior — push
  these as soon as written.
- **Phase 2** (`LocalExec`) ✅ shipped. Module, tests, and
  `scripts/build_eprover.sh` are in. The known-good local prover and SZS
  output it produces are now available as the oracle for Phase 3.
- **Phase 2.5** (`AtpClient.Backend` behaviour, `Config.Field`,
  `Isabelle.SessionOwner`) ✅ shipped. Smart Cell groundwork plus an
  Isabelle robustness fix; see the dedicated section above.
- **Phase 3** (StarExec) is the long pole. Give yourself a buffer; validation
  will almost certainly surface at least one real bug in `star_exec.ex`
  (cookies → multipart → completion predicate, in that likelihood order).
- **Open the David collaboration track early** (it runs asynchronously on his
  timeline) but treat its deliverables as Phase 5, not blockers.
- **Phase 4** rewrites land last, after Phase 3 outcomes are known.
- **Phase 5** only if time remains.

## Open items / decisions needed

- [ ] Confirm the camera-ready deadline for PAAR'26 (drives buffer sizing for
      Phase 3 and the David track).
- [ ] Choose the StarExec deployment vehicle (ARC standalone vs. self-built
      Compose) — decide after ~half a day with ARC.
- [x] Decide whether `list_provers/0` becomes blocking-on-first-call or stays
      async-with-docs — **blocking on first call** with `:refresh_timeout_ms`
      (default 15 s) and `[]` fallback on timeout.
- [ ] Decide whether the probe-style Sledgehammer usage gets its own sentence
      in §3 or is folded into the general clarification.
- [x] Decide whether `LocalExec` exposes a portfolio/parallel mode or stays
      single-binary for camera-ready — **single-binary**, portfolio noted as
      future work.
- [x] Decide whether wall-clock timeout gets a distinct `atp_result` variant
      or folds into `:timeout` — **folded into `{:ok, :timeout}`** to keep
      the cross-backend result type uniform.
- [ ] Confirm with David which of the delegated items he can take and on what
      timeline; pin the `isabelle_elixir` version accordingly.
- [ ] Decide MCP server prominence: §9 demonstration only (default) vs.
      promote to multi-backend (Phase 5, only if Phases 0–3 are done).
