# StarExec Phase 3 validation smoke test.
#
# Run: mix run examples/starexec_smoke_test.exs
#
# Prerequisites (complete in the StarExec web UI at https://localhost:7827 before running):
#   1. StarExec container is up: external/starexec-containerised/start.sh start
#   2. Log in as admin:admin and create a Space (note its numeric ID).
#   3. Upload E prover (from priv/bin/eprover, packaged as a StarExec .tgz solver) into the space.
#      Note the solver config ID shown in "View Solver".
#   4. Upload two TPTP benchmarks to the space:
#        theorem            — e.g. PUZ001+1.p (SZS status Theorem). Any TPTP
#                             problem whose header says `% Status : Theorem`
#                             (FOF) or `Unsatisfiable` (CNF) works.
#        countersatisfiable — a problem whose header says
#                             `% Status : CounterSatisfiable` (FOF) or
#                             `Satisfiable` (CNF). TPTP's `+` / `-` / `^`
#                             suffixes only encode the form (FOF/CNF/THF),
#                             NOT the SZS status — `PUZ001-1.p` is *not*
#                             CounterSatisfiable, it is the CNF form of
#                             Schubert's Steamroller and is a theorem.
#                             A trivial handcrafted CSA benchmark:
#                                 fof(a1, axiom, p(a)).
#                                 fof(c1, conjecture, p(b)).
#      Note each benchmark ID.
#   5. Set the env vars below and re-run.
#
# Environment variables:
#   STAREXEC_SPACE_ID        numeric space ID
#   STAREXEC_SOLVER_CFG_ID   numeric solver *configuration* ID (not solver ID)
#   BENCH_THM_ID             benchmark ID for the Theorem problem
#   BENCH_CSAT_ID            benchmark ID for the CounterSatisfiable problem
#   STAREXEC_QUEUE_ID        worker queue ID (defaults to "1", the container's all.q)
#
# After a successful run, copy the job JSON fixture saved to
# test/fixtures/starexec_job_complete.json and the stdout fixtures to
# test/fixtures/starexec_stdout_*.txt for offline regression coverage.

Mix.Task.run("app.start")

alias AtpClient.{StarExec, ResultNormalization}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

base_url = "https://localhost:7827"
opts = [
  base_url: base_url,
  username: "admin",
  password: "admin",
  request_timeout_ms: 30_000,
  # Skip TLS verification for the self-signed certificate the container generates.
  connect_options: [transport_opts: [verify: :verify_none]]
]

space_id      = System.get_env("STAREXEC_SPACE_ID")      || raise "Set STAREXEC_SPACE_ID"
solver_cfg_id = System.get_env("STAREXEC_SOLVER_CFG_ID") || raise "Set STAREXEC_SOLVER_CFG_ID"
bench_thm_id  = System.get_env("BENCH_THM_ID")           || raise "Set BENCH_THM_ID"
bench_csat_id = System.get_env("BENCH_CSAT_ID")          || raise "Set BENCH_CSAT_ID"
# StarExec needs a worker queue id; the default container's "all.q" is 1.
queue_id      = System.get_env("STAREXEC_QUEUE_ID")      || "1"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

defmodule SmokeTest do
  def assert_eq!(label, got, expected) do
    if got == expected do
      IO.puts("  PASS  #{label}: #{inspect(got)}")
    else
      IO.puts("  FAIL  #{label}: expected #{inspect(expected)}, got #{inspect(got)}")
      System.halt(1)
    end
  end

  # `AtpClient.StarExec.create_job/3` (0.6.0+) returns `{:ok, job_id}` on the
  # normal 302 redirect path and `{:error, {:create_job_failed, %{status,
  # message}}}` for anything else. `message` is the StarExec
  # `STATUS_MESSAGE_STRING` cookie value when set.
  def unwrap_job_id!({:ok, id}) when is_integer(id), do: id

  def unwrap_job_id!({:error, {:create_job_failed, %{status: status, message: msg}}}) do
    raise """
    create_job failed with status #{status}.
      StarExec reason: #{msg || "(none)"}
    """
  end

  def unwrap_job_id!({:error, reason}), do: raise("create_job failed: #{inspect(reason)}")

  # The j_outputs ZIP from /secure/download contains one stdout file per pair
  # under a directory layout like Job<id>/<space>/<bench>/<solver>/<config>/.
  # For a smoke job with a single bench × single config there is exactly one
  # such file; we just grab it.
  def extract_single_stdout!(zip_bytes, job_info \\ nil) do
    {:ok, entries} = :zip.extract(zip_bytes, [:memory])

    stdout_entries =
      entries
      |> Enum.filter(fn
        {name, content} when is_binary(content) -> not String.ends_with?(to_string(name), "/")
        _ -> false
      end)

    case stdout_entries do
      [{_name, content}] ->
        content

      [] ->
        raise """
        j_outputs ZIP contained no files — the StarExec worker produced no stdout.
        #{job_diagnostic(job_info)}
        Check the pair status in the web UI:
          https://localhost:7827/starexec/secure/details/job.jsp?id=#{job_id(job_info)}
        and the container log:
          podman logs starexec-app | tail -200
        Common causes: solver tgz missing `bin/starexec_run_default`, run-script
        not executable, or eprover binary incompatible with the worker node.
        """

      many ->
        names = Enum.map(many, fn {n, _} -> to_string(n) end)
        raise "Expected a single stdout entry, got #{length(many)}: #{inspect(names)}"
    end
  end

  defp job_diagnostic(%{"diskSize" => d, "totalPairs" => t}),
    do: "Job DTO reports diskSize=#{d} bytes across totalPairs=#{t}."

  defp job_diagnostic(_), do: ""

  defp job_id(%{"id" => id}), do: id
  defp job_id(_), do: "<unknown>"

  # Form field names mirror the StarExec "Add Job" form (`secure/add/job.jsp`)
  # and the validation in `org.starexec.servlets.CreateJob#isValid`. Required
  # fields: sid, benchmarkingFramework, seed, queue, desc, runChoice, plus
  # benchChoice + bench + configs for the "choose / runChosenFromSpace" path.
  # preProcess / postProcess must parse as ints — "-1" means "none".
  def job_fields(space_id, queue_id, solver_cfg_id, bench_id, label, cpu_timeout_s) do
    %{
      "sid"                   => space_id,
      "name"                  => "AtpClient smoke — #{label}",
      "desc"                  => "Automated validation run",
      "queue"                 => queue_id,
      "benchmarkingFramework" => "RUNSOLVER",
      "seed"                  => "0",
      "preProcess"            => "-1",
      "postProcess"           => "-1",
      "cpuTimeout"            => to_string(cpu_timeout_s),
      "wallclockTimeout"      => to_string(cpu_timeout_s * 2),
      "maxMem"                => "1.0",
      "runChoice"             => "choose",
      "benchChoice"           => "runChosenFromSpace",
      "bench"                 => bench_id,
      "configs"               => solver_cfg_id,
      # `pause` is unconditionally dereferenced via .equals("yes") in
      # CreateJob#doPost — omitting it causes an uncaught NPE (HTTP 500).
      "pause"                 => "no"
    }
  end
end

# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------

IO.puts("\n=== Login ===")
{:ok, session} = StarExec.login(opts)
IO.puts("Cookies received: #{inspect(Map.keys(session.cookies))}")

# ---------------------------------------------------------------------------
# Case 1: Theorem
# ---------------------------------------------------------------------------

IO.puts("\n=== Case 1: Theorem ===")
fields_thm = SmokeTest.job_fields(space_id, queue_id, solver_cfg_id, bench_thm_id, "Theorem", 30)
job_id_thm = SmokeTest.unwrap_job_id!(StarExec.create_job(session, fields_thm, opts))
IO.puts("Job ID: #{job_id_thm}")

{:ok, job_info_thm} = StarExec.wait_for_job(session, job_id_thm, Keyword.merge(opts, timeout_ms: 120_000))
File.write!("test/fixtures/starexec_job_complete.json", Jason.encode!(job_info_thm, pretty: true))
IO.puts("Saved job JSON fixture → test/fixtures/starexec_job_complete.json")

{:ok, output_zip_thm} = StarExec.get_job_output(session, job_id_thm, opts)
stdout_thm = SmokeTest.extract_single_stdout!(output_zip_thm, job_info_thm)
File.write!("test/fixtures/starexec_stdout_thm.txt", stdout_thm)
IO.puts("Saved stdout fixture → test/fixtures/starexec_stdout_thm.txt")

result_thm = ResultNormalization.interpret_result(stdout_thm)
SmokeTest.assert_eq!("Theorem result", result_thm, {:ok, :theorem})

# ---------------------------------------------------------------------------
# Case 2: CounterSatisfiable
# ---------------------------------------------------------------------------

IO.puts("\n=== Case 2: CounterSatisfiable ===")
fields_csat = SmokeTest.job_fields(space_id, queue_id, solver_cfg_id, bench_csat_id, "CounterSat", 30)
job_id_csat = SmokeTest.unwrap_job_id!(StarExec.create_job(session, fields_csat, opts))

{:ok, job_info_csat} = StarExec.wait_for_job(session, job_id_csat, Keyword.merge(opts, timeout_ms: 120_000))
{:ok, output_zip_csat} = StarExec.get_job_output(session, job_id_csat, opts)
stdout_csat = SmokeTest.extract_single_stdout!(output_zip_csat, job_info_csat)
File.write!("test/fixtures/starexec_stdout_csat.txt", stdout_csat)
IO.puts("Saved stdout fixture → test/fixtures/starexec_stdout_csat.txt")

result_csat = ResultNormalization.interpret_result(stdout_csat)
SmokeTest.assert_eq!("CounterSat result", result_csat, {:ok, :counter_satisfiable})

# ---------------------------------------------------------------------------
# Logout and summary
# ---------------------------------------------------------------------------

IO.puts("\n=== Logout ===")
:ok = StarExec.logout(session, opts)

IO.puts("""

=== ALL SMOKE TESTS PASSED ===

Next step: use the saved fixtures in test/fixtures/ to write offline
regression tests in test/atp_client/star_exec_test.exs that stub Req with
the recorded payloads.
""")
