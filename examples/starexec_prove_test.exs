# End-to-end exercise of `AtpClient.StarExec.prove/3`.
#
# Run: mix run examples/starexec_prove_test.exs
#
# Prerequisites (set up once in the StarExec web UI):
#   1. Container running: external/starexec-containerised/start.sh start
#   2. A solver uploaded (e.g. priv/bin/eprover.zip) into a space, with an
#      auto-discovered configuration named `default`.
#
# Unlike the smoke test, this script does NOT need pre-uploaded benchmarks —
# `prove/3` uploads each problem itself, runs it, and returns the normalized
# SZS result.
#
# Environment variables:
#   STAREXEC_SPACE_ID        numeric space ID
#   STAREXEC_SOLVER_CFG_ID   numeric solver *configuration* ID
#   STAREXEC_QUEUE_ID        worker queue ID (defaults to "1", the container's all.q)

Mix.Task.run("app.start")

alias AtpClient.StarExec

opts = [
  base_url: "https://localhost:7827",
  username: "admin",
  password: "admin",
  request_timeout_ms: 30_000,
  connect_options: [transport_opts: [verify: :verify_none]],
  space_id: String.to_integer(System.get_env("STAREXEC_SPACE_ID") || raise("Set STAREXEC_SPACE_ID")),
  solver_cfg_id:
    String.to_integer(System.get_env("STAREXEC_SOLVER_CFG_ID") || raise("Set STAREXEC_SOLVER_CFG_ID")),
  queue_id: String.to_integer(System.get_env("STAREXEC_QUEUE_ID") || "1"),
  cpu_timeout_s: 30,
  timeout_ms: 180_000
]

# A trivial theorem: p(a) ∧ ∀x.(p(x) → q(x)) ⊢ q(a)
theorem = """
fof(a1, axiom, p(a)).
fof(a2, axiom, ![X]: (p(X) => q(X))).
fof(c1, conjecture, q(a)).
"""

# A trivial countersatisfiable problem: p(a) ⊬ p(b)
countersat = """
fof(a1, axiom, p(a)).
fof(c1, conjecture, p(b)).
"""

IO.puts("\n=== Login ===")
{:ok, session} = StarExec.login(opts)

IO.puts("\n=== Theorem case ===")
result_thm = StarExec.prove(session, theorem, opts)
IO.puts("prove/3 returned: #{inspect(result_thm)}")
{:ok, :thm} = result_thm

IO.puts("\n=== CounterSatisfiable case ===")
result_csat = StarExec.prove(session, countersat, opts)
IO.puts("prove/3 returned: #{inspect(result_csat)}")
{:ok, :csat} = result_csat

IO.puts("\n=== Logout ===")
:ok = StarExec.logout(session, opts)

IO.puts("""

=== prove/3 end-to-end OK ===
""")
