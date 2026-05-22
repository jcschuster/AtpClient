# Roadmap: PAAR'26 "Elixir meets TPTP" → Camera-Ready

This document maps reviewer comments to concrete revision tasks, in the order
they should be tackled. Phases are ordered by dependency: textual fixes and
code-shipping prerequisites land first; the StarExec validation effort is the
long pole; strategic framing follows once validation outcomes are known.

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
- **Document the `list_provers/0` race (16B).** The prover list is
  populated asynchronously, so `list_provers/0` returns `[]` immediately
  after startup. Two options:
  - *Preferred:* make `list_provers/0` block on first call until
    populated, with a configurable timeout. Removes a footgun rather than
    documenting it.
  - *Minimum:* add a `@doc` note + a README paragraph pointing at
    `refresh_systems_list/0`.

Both fixes need to be in a released version before the paper can describe
the fixed behavior.

---

## Phase 2 — StarExec validation via local container

This is the headline review-response. It turns 16C from "weak accept
conditional on testing" into a clean accept, and lets §1's contribution
claim survive contact with §7.

### Deployment vehicle

The original `StarExec/StarExec` is a heavy Tomcat 7.0.64 + MySQL + Ant +
SCSS stack that hasn't been Docker-packaged upstream. Realistic options:

1. **`StarExecMiami/StarExec-ARC`** — the Miami group (Sutcliffe's group,
   same TPTP-world ecosystem) maintains a containerized fork using Podman +
   microK8s/EKS, and the repo has a `starexec-containerised` subdirectory
   aimed at standalone Podman use. Cleanest path because it's actively
   maintained and aligned with the community you're publishing into.
2. **Self-built Docker Compose** wrapping the upstream `StarExec/StarExec`
   if ARC turns out to lift things you don't need (SGE backend, Kubernetes
   orchestration). More work but tighter scope.

Start with (1); fall back to (2) only if blocked.

### Validation procedure

The minimum end-to-end test that earns the "validated" claim:

1. Bring up the container; create an admin user; create a "space" with one
   solver (E or Vampire suffices — both speak TPTP+SZS natively) and one
   trivial benchmark.
2. From `iex`, exercise the full path: `login/1` → `create_job/3` with the
   actual field set your local instance expects → extract `job_id` from
   the redirect → `wait_for_job/3` → `get_pair_stdout/3` →
   `ResultNormalization.interpret_result/1` returning `{:ok, :thm}`.
3. Repeat with a benchmark producing `Timeout` and one producing
   `CounterSatisfiable`, so the SZS classifier path is exercised, not just
   the happy path.
4. Capture the exact `create_job` field set that worked. Either embed a
   working example in the README or, better, ship
   `examples/starexec_smoke_test.exs` in the repo and reference it from
   the paper.

### Code likely to need touching

Validation will almost certainly surface real bugs — `star_exec.ex` was
written against documentation, not a live instance. Plausible suspects:

- **Cookie handling** for Tomcat's `JSESSIONID` + the StarExec session
  cookie. Some deployments set both; `extract_cookies/1` currently treats
  the jar as flat.
- **`default_complete?/1`** may not match the actual JSON shape your local
  instance returns. The `:complete_fun` is configurable for exactly this,
  but the default should ideally work out of the box.
- **Job-id extraction** from the create-job response is currently left to
  the caller; consider a helper `extract_job_id/1` that handles the
  redirect-location parsing for the common case.

### Paper integration

Rewrite §7's "StarExec Validation Status" paragraph along these lines:

> We validated the StarExec backend end-to-end against a self-hosted
> instance deployed via [ARC / Docker Compose], exercising authentication,
> job submission, polling, and SZS-normalized result retrieval against E
> and Vampire on representative TPTP problems. The smoke-test script is
> shipped with the repository.

If validation also surfaces a real interop gotcha worth reporting (e.g.,
cookie ordering, completion-predicate variance across StarExec versions),
promote it from a fix-it-and-move-on into a paragraph. It materially
strengthens the "we handle the messy reality" framing and helps address
16A's depth-of-contribution worry.

---

## Phase 3 — Strategic framing & related work

Harder edits — repositioning rather than fixing.

- **Related work expansion (16B).** Add `online-atps` (Prieto), `aztek/atp`,
  and the `tptp` Haskell package to §8 with brief comparison. Honest
  framing: `online-atps` overlaps cleanly with our SystemOnTPTP coverage
  but is single-backend; the Haskell `tptp` packages cover parsing rather
  than service integration. This *strengthens* the paper because it makes
  "unified across three backends + Livebook" the differentiator rather
  than "we talk to SystemOnTPTP."
- **Livebook introduction + honest Jupyter comparison (16B).** §5 assumes
  the reader knows Livebook. Add a paragraph at the top: what Livebook is
  (Elixir-native reactive notebook), what Smart Cells are (live processes
  with custom UI sharing the notebook's BEAM node, not just rendered
  cells), and an honest note on adoption cost (requires installing
  Elixir). Then clarify 16B's black-box-GUI question: yes, the Smart Cell
  is usable without writing Elixir for one-off TPTP editing and prover
  invocation, but composing it into a workflow needs Elixir.
- **Response to 16A on contribution depth.** Don't try to defeat 16A
  head-on — the reviewer is correct that an SystemOnTPTP wrapper is a
  small layer in isolation. The reframing 16B already pointed toward is
  the right move: the contribution isn't "we talk to ATPs," it's "we make
  ATP access a first-class citizen of the BEAM agent-infrastructure
  ecosystem, with unified semantics across three structurally very
  different backends, fault-tolerant polling, and an interactive
  front-end." The validated StarExec backend (Phase 2) turns this from a
  claim into a demonstration. Tighten the intro and §6 to lead with this
  framing.

---

## Phase 4 — Stretch (only if Phases 0–3 are comfortably done)

16C suggested non-blocking improvements worth taking seriously if time
permits:

- **Local solver backend.** A fourth backend `AtpClient.LocalExec` that
  shells out to a locally installed TPTP-compliant prover.
  Architecturally similar to but simpler than StarExec — no auth, no
  polling, just `System.cmd/3` with timeout and SZS parsing. *Note:* the
  repo already has a `local.ex` file (the Lint module); pick a different
  namespace to avoid confusion.
- **Faster TPTP4X via local invocation.** Same idea applied to the
  linter's authoritative tier — invoke a locally installed `tptp4X`
  binary instead of round-tripping over HTTP. The hybrid lint
  architecture already supports swapping the remote tier; this becomes a
  Smart Cell config toggle.
- **Richer result fields.** Extending `atp_result` with optional runtime,
  proof-clause count, and prover-specific stats. Bigger API design
  question (struct? map? sibling `atp_meta`?) — probably belongs in
  future work for the paper, not the camera-ready.

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

- Phase 0 textual fixes in parallel with starting Phase 2 container
  setup (the container brings itself up while you do textual fixes).
- Phase 1 fixes need to land in a Hex release before the paper can cite
  the fixed behavior — push these as soon as written.
- Phase 2 is the long pole. Give yourself a buffer; validation will
  almost certainly surface at least one real bug in `star_exec.ex`.
- Phase 3 rewrites land last, after you know what Phase 2 produced.
- Phase 4 only if time remains.

## Open items / decisions needed

- [ ] Confirm the camera-ready deadline for PAAR'26 (drives buffer
      sizing for Phase 2).
- [ ] Choose the StarExec deployment vehicle (ARC vs. self-built
      Compose) — decide after spending ~half a day with ARC.
- [ ] Decide whether `list_provers/0` becomes blocking-on-first-call or
      stays async-with-docs.
- [ ] Decide whether the probe-style Sledgehammer usage gets its own
      sentence in §3 or is folded into the general clarification.
