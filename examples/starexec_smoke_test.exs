# StarExec Phase 3 validation smoke test.
#
# Run: mix run examples/starexec_smoke_test.exs
#
# Prerequisites (complete in the StarExec web UI at https://localhost:7827 before running):
#   1. StarExec container is up: external/starexec-containerised/start.sh start
#   2. Log in as admin:admin and create a Space (note its numeric ID).
#   3. Upload E prover (from priv/bin/eprover, packaged as a StarExec .tgz solver) into the space.
#      Note the solver config ID shown in "View Solver".
#   4. Upload at least three TPTP benchmarks to the space:
#        theorem      — e.g. PUZ001+1.p  (SZS status Theorem)
#        timeout      — a hard problem with a 5 s CPU limit
#        countersatisfiable — e.g. PUZ001-1.p  (SZS status CounterSatisfiable)
#      Note each benchmark ID.
#   5. Set the four env vars below and re-run.
#
# Environment variables:
#   STAREXEC_SPACE_ID        numeric space ID
#   STAREXEC_SOLVER_CFG_ID   numeric solver *configuration* ID (not solver ID)
#   BENCH_THM_ID             benchmark ID for the Theorem problem
#   BENCH_CSAT_ID            benchmark ID for the CounterSatisfiable problem
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

  # Extract job_id from a Location header like "/starexec/secure/details/job.jsp?jobId=42"
  # or "/starexec/secure/jobs/42".
  def extract_job_id!(headers) do
    location =
      Enum.find_value(headers, fn {k, v} ->
        if String.downcase(k) == "location", do: v
      end) || raise "No Location header in create_job response"

    case Regex.run(~r/jobId=(\d+)|\/jobs\/(\d+)/, location) do
      [_, id, ""] -> String.to_integer(id)
      [_, "", id] -> String.to_integer(id)
      _ -> raise "Could not parse job_id from Location: #{location}"
    end
  end

  def first_pair_id!(job_info) do
    case job_info do
      %{"jobPairs" => [%{"jobPairId" => id} | _]} -> id
      %{"pairs" => [%{"pairId" => id} | _]} -> id
      _ -> raise "Unexpected job JSON shape — update pair_id extraction:\n#{inspect(job_info, pretty: true)}"
    end
  end

  # NOTE (Phase 3 action item): discover the real field names by opening the
  # "Add Job" page in the StarExec web UI against your local instance and
  # inspecting the network tab. Common fields vary across StarExec releases.
  # Known stable fields: name, desc, sid, cpuTimeout, wallclockTimeout.
  # Solver/config and benchmark selection are often multi-value and may require
  # multipart encoding — see ROADMAP.md Phase 3 known risk #2.
  def job_fields(space_id, solver_cfg_id, bench_id, label, cpu_timeout_s) do
    %{
      "name"             => "AtpClient smoke — #{label}",
      "desc"             => "Automated validation run",
      "sid"              => space_id,
      "cpuTimeout"       => to_string(cpu_timeout_s),
      "wallclockTimeout" => to_string(cpu_timeout_s * 2),
      # TODO: Verify these field names against your instance's "Add Job" form.
      # They may be "sc" (solver config), "bench", "benchmarkIds", etc.
      "sc"               => solver_cfg_id,
      "bench"            => bench_id
    }
  end
end

# ---------------------------------------------------------------------------
# Login (validates cookie handling — ROADMAP Phase 3 known risk #1)
# ---------------------------------------------------------------------------

IO.puts("\n=== Login (with verbose probe) ===")

# Manual two-step probe so we can see what Tomcat returns at each stage.
probe_req =
  Req.new(
    base_url: opts[:base_url],
    redirect: false,
    connect_options: opts[:connect_options]
  )

{:ok, get_resp} = Req.get(probe_req, url: "/starexec/secure/explore/spaces.jsp")
IO.puts("  GET /starexec/secure/explore/spaces.jsp -> #{get_resp.status}")
IO.puts("    Set-Cookie: #{inspect(for {k, v} <- get_resp.headers, String.downcase(k) == "set-cookie", do: v)}")

cookie_jar =
  get_resp.headers
  |> Enum.flat_map(fn
    {"set-cookie", v} -> List.wrap(v)
    {"Set-Cookie", v} -> List.wrap(v)
    _ -> []
  end)
  |> Enum.map(fn raw ->
    raw |> String.split(";", parts: 2) |> hd() |> String.split("=", parts: 2)
  end)
  |> Enum.into(%{}, fn [k, v] -> {String.trim(k), String.trim(v)} end)

cookie_header = Enum.map_join(cookie_jar, "; ", fn {k, v} -> "#{k}=#{v}" end)
IO.puts("    Cookie header for next request: #{cookie_header}")

{:ok, post_resp} =
  Req.post(probe_req,
    url: "/starexec/j_security_check",
    body: URI.encode_query(%{"j_username" => "admin", "j_password" => "admin"}),
    headers: [
      {"content-type", "application/x-www-form-urlencoded"},
      {"cookie", cookie_header}
    ]
  )

IO.puts("  POST /starexec/j_security_check -> #{post_resp.status}")
IO.puts("    Location: #{inspect(for {k, v} <- post_resp.headers, String.downcase(k) == "location", do: v)}")
IO.puts("    Set-Cookie: #{inspect(for {k, v} <- post_resp.headers, String.downcase(k) == "set-cookie", do: v)}")

{:ok, session} = StarExec.login(opts)
IO.puts("Cookies received: #{inspect(Map.keys(session.cookies))}")
IO.puts("(If the list is empty the login succeeded but no cookie was set — see ROADMAP cookie risk.)")

# ---------------------------------------------------------------------------
# Case 1: Theorem
# ---------------------------------------------------------------------------

IO.puts("\n=== Case 1: Theorem ===")
fields_thm = SmokeTest.job_fields(space_id, solver_cfg_id, bench_thm_id, "Theorem", 30)
{:ok, resp_thm} = StarExec.create_job(session, fields_thm, opts)
IO.puts("create_job status: #{resp_thm.status}")
IO.puts("Location: #{inspect(Enum.find_value(resp_thm.headers, fn {k,v} -> if String.downcase(k)=="location", do: v end))}")

job_id_thm = SmokeTest.extract_job_id!(resp_thm.headers)
IO.puts("Job ID: #{job_id_thm}")

{:ok, job_info_thm} = StarExec.wait_for_job(session, job_id_thm, Keyword.merge(opts, timeout_ms: 120_000))
File.write!("test/fixtures/starexec_job_complete.json", Jason.encode!(job_info_thm, pretty: true))
IO.puts("Saved job JSON fixture → test/fixtures/starexec_job_complete.json")

pair_id_thm = SmokeTest.first_pair_id!(job_info_thm)
{:ok, stdout_thm} = StarExec.get_pair_stdout(session, pair_id_thm, opts)
File.write!("test/fixtures/starexec_stdout_thm.txt", stdout_thm)
IO.puts("Saved stdout fixture → test/fixtures/starexec_stdout_thm.txt")

result_thm = ResultNormalization.interpret_result(stdout_thm)
SmokeTest.assert_eq!("Theorem result", result_thm, {:ok, :thm})

# ---------------------------------------------------------------------------
# Case 2: CounterSatisfiable
# ---------------------------------------------------------------------------

IO.puts("\n=== Case 2: CounterSatisfiable ===")
fields_csat = SmokeTest.job_fields(space_id, solver_cfg_id, bench_csat_id, "CounterSat", 30)
{:ok, resp_csat} = StarExec.create_job(session, fields_csat, opts)
job_id_csat = SmokeTest.extract_job_id!(resp_csat.headers)

{:ok, job_info_csat} = StarExec.wait_for_job(session, job_id_csat, Keyword.merge(opts, timeout_ms: 120_000))
pair_id_csat = SmokeTest.first_pair_id!(job_info_csat)
{:ok, stdout_csat} = StarExec.get_pair_stdout(session, pair_id_csat, opts)
File.write!("test/fixtures/starexec_stdout_csat.txt", stdout_csat)
IO.puts("Saved stdout fixture → test/fixtures/starexec_stdout_csat.txt")

result_csat = ResultNormalization.interpret_result(stdout_csat)
SmokeTest.assert_eq!("CounterSat result", result_csat, {:ok, :csat})

# ---------------------------------------------------------------------------
# Logout and summary
# ---------------------------------------------------------------------------

IO.puts("\n=== Logout ===")
:ok = StarExec.logout(session, opts)

IO.puts("""

=== ALL SMOKE TESTS PASSED ===

Next steps for ROADMAP Phase 3:
  1. Verify the field names used in job_fields/5 above were correct — if a
     create_job call returned a non-redirect status, the field set needs updating.
  2. Check whether multipart encoding was needed (ROADMAP known risk #2).
  3. Review the saved fixtures in test/fixtures/ and write offline regression
     tests in test/atp_client/star_exec_test.exs using the fixture payloads.
  4. Update ROADMAP §7 with a validation report.
""")
