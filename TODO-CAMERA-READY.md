# TODO — PAAR'26 Camera-Ready ("Elixir meets TPTP")

Status snapshot (2026-06-23): the hard engineering work is done; almost
nothing has landed in the paper yet. Reviewer concerns are the spine of
this list; pragmatic code/paper-sync items follow.

Cross-references: reviews in `external/paar-reviews-16.txt`, paper source
in `external/main.tex`, plan of record in `ROADMAP.md`, change log in
`CHANGELOG.md`.

---

## A. Reviewer-driven — must land

### A.1 Paper text (Phase 0 — none applied yet)

- [ ] **16A · Figure 1 / `:thm` semantics.** Line 110 still has
  `theorem "..." sledgehammer oops` returning `{:ok, :thm}`. Switch the
  Isabelle example in `fig:unified-api` to `by auto` (or similar). In §3,
  near the `atp_result` introduction, add the explicit semantics:
  > Across all backends, `:thm` reflects the prover's or tool's claim of
  > success, not kernel verification. For stronger guarantees within
  > Isabelle, use `by`-style proof methods that submit a proof term to
  > the kernel.

- [ ] **16B · `:sat` footnote 6.** Line 144's footnote is still bare.
  Promote to one or two sentences in §3 explaining that SZS
  `Satisfiable` refers to the *negation* being countersatisfiable, while
  `nitpick[satisfy]` models the formula itself as a positive existence
  claim; note that this deviation affects only the Isabelle backend
  (SystemOnTPTP results map `Satisfiable → :csat` per Table 1).

- [ ] **16C · `\Cref` capitalization.** Configure `cleveref` to always
  capitalize, or replace lowercase `\cref` at sentence-initial positions
  by `\Cref`. Several occurrences in §2/§4/§5/§7.

- [ ] **16B · Figure 2 caption.** Add OS and browser to the
  `screenshot_smart_cell.png` caption (currently no occurrence of
  `OS|browser|Firefox|Chrome` anywhere in `main.tex`).

- [ ] **16B · Quantify SZS fallback coverage.** Add one sentence to §3:
  N prover-specific patterns covering M provers (Alt-Ergo, E, SPASS,
  Vampire, Waldmeister). Numbers are implicit in
  `lib/atp_client/result_normalization.ex`.

- [ ] **16B · Reconcile §1 ↔ §7 ↔ §9 on StarExec.** Now that validation
  has shipped (commit `5e81f32`, fixtures in `test/fixtures/`), all
  three places must be rewritten:
  - §1 line 67 can keep StarExec as a contribution (now defensible).
  - §7 line 248–250 ("StarExec Validation Status") must change from
    "we have not been able to validate it end-to-end" to a validation
    report: container deployment vehicle, what was exercised (auth, job
    submission, polling, SZS normalization on Theorem +
    CounterSatisfiable benchmarks), pointer to
    `examples/starexec_smoke_test.exs` and `starexec_prove_test.exs`,
    saved fixtures. If a real interop gotcha is worth reporting
    (cookies, multipart, completion predicate), promote it to a short
    paragraph — it addresses 16A's depth concern.
  - §9 line 262 must drop "end-to-end validation of the StarExec
    backend" from future work.

### A.2 Paper text (Phase 4 — none applied yet)

- [ ] **16B · Livebook introduction + honest Jupyter comparison (§5).**
  Add a paragraph at the top of §5 explaining what Livebook is
  (Elixir-native reactive notebook), what Smart Cells are (live
  processes with custom UI sharing the notebook's BEAM node), and an
  honest note on adoption cost (requires installing Elixir). Then
  answer 16B's black-box-GUI question: the Smart Cell is usable without
  writing Elixir for one-off TPTP editing and prover invocation, but
  composing it into a workflow needs Elixir. (Confirmed against
  `KinoAtpClient` README — it currently provides no black-box-GUI
  guidance.)

- [ ] **16B · Related work expansion (§8).** No occurrences of
  `online-atps`, `Prieto`, `aztek`, or "Haskell" anywhere in `main.tex`
  or `main.bib`. Add `online-atps` (Prieto,
  <https://github.com/jonaprieto/online-atps>) with a brief contrast
  (single-backend SystemOnTPTP wrapper vs. our unified four-backend
  surface). Mention the `aztek/atp` and `tptp` Haskell packages and
  distinguish parser-level scope from service-integration scope.

- [ ] **16A · Depth-of-contribution reframing.** Tighten the §1 intro
  and §6 scenarios to lead with "first-class BEAM
  agent-infrastructure citizen": unified semantics across structurally
  different backends, fault-tolerant polling, interactive front-end. The
  validated StarExec backend, the LocalExec backend, and the §9 MCP
  demonstration (if included) are the three concrete demonstrations
  that back the framing.

### A.3 Code (already shipped — for reference)

- [x] Auto-load default config (`Config.@defaults` merged per-key, commit
      `e79df90`).
- [x] `list_provers/0` race fixed (blocking on first call, default
      15 s timeout, `[]` fallback).
- [x] `AtpClient.LocalExec` backend with two-layer timeout, fake-binary
      tests, `scripts/build_eprover.sh`.
- [x] `AtpClient.Backend` behaviour, `Config.Field` struct,
      `Isabelle.SessionOwner` for caller-safe Isabelle sessions.
- [x] **StarExec end-to-end validation** (commit `5e81f32`, 2026-06-22).
      `examples/starexec_smoke_test.exs`, `examples/starexec_prove_test.exs`,
      `test/fixtures/starexec_job_complete.json`,
      `test/fixtures/starexec_stdout_thm.txt`,
      `test/fixtures/starexec_stdout_csat.txt`.

---

## B. Pragmatic (code shipped without corresponding paper update)

- [ ] **LocalExec is unmentioned in the paper.** `LocalExec` /
  "local solver" do not appear anywhere in `main.tex`. §1's three-bullet
  contribution list still names three backends; §3 doesn't describe
  LocalExec; §9 omits it. Add a paragraph in §3 (two-layer timeout is
  worth one sentence as the "messy reality" example for 16A), include
  it in §1's contributions, and pick it up in §6's portfolio scenario.
  Also addresses 16C's "support locally installed solvers" comment
  directly.

- [ ] **Cancellation API also unmentioned.** Commit `b0eada1`
  (2026-06-22) added a cross-backend cancellation API not in the
  ROADMAP and not in the paper. Decide: brief note in §3 / §4, or stay
  silent.

- [ ] **`isabelle_elixir` dependency.** `mix.exs` currently has
  `{:isabelle_elixir, github: "davfuenmayor/isabelle_elixir",
  branch: "main"}`. The published Hex `0.3.0` (2026-05-30) does **not**
  contain `IsabelleClient.TPTP` — that module landed on `main` on
  2026-06-14 and is unreleased. A camera-ready that claims "available
  on Hex" needs either (a) a David-side cut of `0.3.1` / `0.4.0` and a
  re-pin to a Hex constraint, or (b) explicit documentation in the
  README that the git pin is required for the TPTP entry points.

- [ ] **KinoAtpClient `main` is still SystemOnTPTP-only.** HEAD
  (`5dcd08a`, 2026-06-14) keeps `@version "0.1.4"` and pins
  `atp_client ~> 0.2`. The only Smart Cell registered in
  `lib/kino_atp_client/application.ex` is `KinoAtpClient.SystemOnTptp`;
  nothing in `lib/` references `AtpClient.Backend`,
  `AtpClient.backends/0`, `StarExec`, `Isabelle`, or `LocalExec`. The
  June commits on `main` (`f28fdb3` syntax highlighting, `5dcd08a`
  resize option) are output-pane UI work, not backend wiring, and the
  README still describes the package as "Smart Cells for connecting to
  external provers on SystemOnTptp". If §5's framing is meant to span
  all four backends, `main` itself needs the multi-backend port
  (consume `AtpClient.backends/0`, lift the `atp_client` pin to a
  version exposing the behaviour). Otherwise §5 should be explicit
  that the Smart Cell currently targets SystemOnTPTP only.

- [ ] **AtpMcp `main` is now multi-backend and on the current protocol
  revision — but Hex-unreleased and git-pinned to AtpClient.** HEAD
  (`5ab5f71`, 2026-06-24) bumps `@version` to `0.2.0`, declares
  `@protocol_version "2025-11-25"` (`lib/atp_mcp.ex:64`), and routes
  through the unified `AtpClient.Backend` contract for all four
  backends — `lib/atp_mcp.ex:68-71` maps `"sotptp" → SystemOnTptp`,
  `"isabelle" → Isabelle`, `"local_exec" → LocalExec`,
  `"starexec" → StarExec`, with a `list_backends` cross-backend tool.
  Both prior concerns (protocol staleness, SystemOnTPTP-only) are
  resolved on `main`. Remaining issues: `mix.exs` now pins
  `{:atp_client, github: "jcschuster/AtpClient"}`, so the same
  Hex-vs-git story as the `isabelle_elixir` item applies — an AtpClient
  Hex cut exposing `AtpClient.Backend` is needed before AtpMcp can be
  cited as "available on Hex". If the MCP server is promoted to §9,
  describe it as the four-backend demonstration it now is, not the
  SystemOnTPTP-only proof-of-concept the previous TODO assumed.

---

## C. Decisions still owed

- [ ] Confirm the camera-ready deadline. Drives the size of the buffer
      for B-items (especially the David-side Hex cut and any
      KinoAtpClient release work).
- [ ] Probe-style Sledgehammer caveat: own §3 sentence, or fold into
      the general `:thm` clarification (A.1, first item)?
- [ ] KinoAtpClient multi-backend release: in scope for camera-ready,
      or explicit "SystemOnTPTP only today" in §5 with multi-backend
      release deferred to §9 future work?
- [ ] MCP server: include as §9 demonstration (one paragraph + small
      figure showing an agent calling `list_backends`, then dispatching
      a problem through the unified backend contract — e.g. a
      SystemOnTPTP-vs-LocalExec comparison — and getting back SZS
      statuses), or stay silent? The figure should reflect the
      four-backend reality now on AtpMcp `main`, not the old
      single-`run_prover` flow.
- [ ] David collaboration deliverables (multi-lemma example, stable
      `Result.Position` contract, technical review of §3
      Isabelle-semantics paragraph): which land before camera-ready vs.
      which become §9 future work?

---

## D. Suggested ordering

1. **Today / this week:** Phase 0 textual fixes (A.1) — they unblock
   nothing but clear the desk. Same edit pass: §1 contributions list
   updated to four backends; §3 LocalExec paragraph; §7 rewrite of the
   StarExec status paragraph.
2. **In parallel:** ping David about a Hex cut covering
   `IsabelleClient.TPTP` so the dependency pin can move off `main`.
3. **Next:** Phase 4 reframing (A.2) — Livebook intro, related work,
   §1/§6 reframing.
4. **Decide and execute B-items** in the order: `isabelle_elixir`
   pin → KinoAtpClient scope call → MCP scope call (the MCP version
   bump and multi-backend wiring already landed on AtpMcp `main`; the
   remaining call is paper framing + the AtpClient Hex cut that lets
   AtpMcp drop its github pin).
5. **Final pass:** make sure §1, §3, §7, §9 all describe the same
   library (four backends, StarExec validated, LocalExec present,
   cancellation API mentioned or not — consistently).
