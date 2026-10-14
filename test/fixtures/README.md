# Test fixtures

Captured from live systems on 2026-10-14 unless noted. Every SystemOnTPTP
request was a POST to `https://tptp.org/cgi-bin/SystemOnTPTPFormReply` with
`NoHTML=1`, `QuietFlag=-q01`, `ProblemSource=FORMULAE` and, per system,
`System___<id>=<id>` and `TimeLimit___<id>=<s>`; only what differs is listed.

Problems used:

- **P1** (theorem): `fof(a1,axiom,![X]:(p(X)=>q(X))). fof(a2,axiom,p(a)). fof(c,conjecture,q(a)).`
- **P2** (satisfiable): `fof(a1,axiom,p(a)). fof(a2,axiom,~p(f(a))). fof(a3,axiom,![X,Y]:(q(X,Y)=>q(Y,X))). fof(a4,axiom,q(a,f(a))). fof(a5,axiom,a!=b).`

## SystemOnTPTP

| File | Request |
|---|---|
| `sotp_list_systems.txt` | `SubmitButton=ListSystems`, `ListStatus=READY`, `QuietFlag=-q0` (174 systems) |
| `system_info_2026-10-14.txt` | `SubmitButton=ReportSelectedSystems`, `SystemInfo=SystemInfo`, `ReportFlag=-q2`, `FORMULAEProblem=fof(a,axiom,p).`, one `System___<id>` per id of `sotp_list_systems.txt` (135 KB) |
| `sotp_x2tptp_e_vampire.txt` | `RunSelectedSystems`, P1, `X2TPTP=-S`, E---3.5.1 and Vampire---5.0.1, 10 s |
| `sotp_raw_e_vampire.txt` | the same without `X2TPTP` |
| `sotp_raw_inappropriate.txt` | `RunSelectedSystems`, P1, Satallax---3.5 (refuses FOF: `says Inappropriate`, no output) and Twee---2.7, 5 s |
| `sotp_x2tptp_inappropriate.txt` | the same with `X2TPTP=-S`: Satallax has no section at all, Twee's derivation could not be converted (`WARNING: Could not form TPTP format derivation`) |
| `sotp_raw_models.txt` | `RunSelectedSystems`, P2, Mace4---2026-6A, Paradox---4.0, Vampire-SAT---5.0.1, E-SAT---3.5.1, cvc5-SAT---1.3.4, 10 s |
| `mace4_finite_model.txt` | lines 1–30 of `sotp_raw_models.txt`: Mace4's section |
| `paradox_finite_model.txt` | lines 31–76 of `sotp_raw_models.txt`: Paradox's section (bare `SZS` lines, no `%`) |
| `e_sat_saturation.txt` | lines 133–251 of `sotp_raw_models.txt`: E-SAT's section, a `Saturation` |
| `vampire_sat_finite_model.txt` | `RunSelectedSystems`, P2, Vampire-FMo---5.0.1, 10 s (Vampire-SAT answers with a `Saturation.` instead) |
| `ecnf_process_problem.txt` | `SubmitButton=ProcessProblem`, `InputFormat=TPTP`, P1, ECNF---3.5.1, 10 s; note the `SZS status Unknown` inside the `ListOfCNF` block |
| `gdv_verified_good.txt` | `SubmitButton=ProcessSolution`, `SolutionFormat=TPTP`, the solution region (lines 36–85) of E's section in `sotp_x2tptp_e_vampire.txt`, GDV---2.0, 30 s |
| `gdv_syntax_error.txt` | the same with `FORMULAEProblem=fof(a,axiom,p(.` |
| `agmv_mace4_model_crash.txt` | `ProcessSolution`, P2 plus `fof(c,conjecture,q(f(a),a)).` plus the model of `mace4_finite_model.txt` (lines 9–24), AGMV---1.0, 30 s: AGMV dies with `Illegal division by zero` and `says Unknown`. With the model alone it answers `SZS status Error … Missing problem or model formulae`. No AGMV `Verified` reply has been observed. |

## Isabelle

Isabelle2025-2, session `HOL`, through `AtpClient.Isabelle.prove_theory/4`;
the file is `result.details.payload` encoded as JSON.

| File | Theory body |
|---|---|
| `isabelle_nitpick_payload.json` | `lemma cex: "⟦f (g x) = y; P x; A ⊆ B⟧ ⟹ g (f y) = x ∧ card A = card (B::'b set)" nitpick [timeout = 30] oops` |
| `isabelle_nitpick_skolem_payload.json` | `lemma sk: "∀x::'a. ∃y::'b. f x = y ∧ P x" nitpick [timeout = 30] oops` |

## StarExec

`starexec_stdout_thm.txt`, `starexec_stdout_csat.txt`, `starexec_job_complete.json`
predate this file (0.7).
