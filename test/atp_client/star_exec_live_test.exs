defmodule AtpClient.StarExecLiveTest do
  use ExUnit.Case, async: false

  # Live tests against a StarExec instance — the sidecar `claude-env`
  # starts beside the container, by default. Excluded by default (see
  # `test/test_helper.exs`); run with:
  #
  #     STAREXEC_URL=http://localhost:7827 STAREXEC_USER=admin STAREXEC_PASS=admin \
  #       mix test --include starexec_live
  #
  # STAREXEC_SPACE_ID names the space solvers and benchmarks are uploaded
  # into (default 1, the root space, which the default admin account owns);
  # STAREXEC_QUEUE_ID the queue jobs are submitted to (default 1).

  @moduletag :starexec_live

  alias AtpClient.StarExec

  @socrates """
  fof(human_mortal, axiom, ! [X] : (human(X) => mortal(X))).
  fof(socrates_human, axiom, human(socrates)).
  fof(socrates_mortal, conjecture, mortal(socrates)).
  """

  setup do
    url = System.get_env("STAREXEC_URL") |> require_env("STAREXEC_URL")
    user = System.get_env("STAREXEC_USER") |> require_env("STAREXEC_USER")
    pass = System.get_env("STAREXEC_PASS") |> require_env("STAREXEC_PASS")
    space_id = System.get_env("STAREXEC_SPACE_ID", "1") |> String.to_integer()
    queue_id = System.get_env("STAREXEC_QUEUE_ID", "1") |> String.to_integer()

    {:ok, session} = StarExec.login(base_url: url, username: user, password: pass)
    on_exit(fn -> StarExec.logout(session) end)

    {:ok, session: session, space_id: space_id, queue_id: queue_id}
  end

  describe "solver upload" do
    test "upload_solver/4 creates a solver whose bin/ scripts are its configurations",
         %{session: session, space_id: space_id} do
      name = "atp_client_test_#{System.unique_integer([:positive])}"

      assert {:ok, solver_id} =
               StarExec.upload_solver(session, space_id, solver_archive(name),
                 name: name,
                 description: "AtpClient live test solver"
               )

      assert is_integer(solver_id)

      assert {:ok, [%{id: cfg_id, name: "default"}]} =
               StarExec.solver_configurations(session, solver_id)

      assert is_integer(cfg_id)
    end

    @tag timeout: 300_000
    test "prove/3 runs a benchmark against an uploaded solver",
         %{session: session, space_id: space_id, queue_id: queue_id} do
      name = "atp_client_test_#{System.unique_integer([:positive])}"

      {:ok, solver_id} =
        StarExec.upload_solver(session, space_id, solver_archive(name), name: name)

      {:ok, [%{id: cfg_id}]} = StarExec.solver_configurations(session, solver_id)

      assert {:ok, %AtpClient.Result{status: :theorem}} =
               StarExec.prove(session, @socrates,
                 space_id: space_id,
                 queue_id: queue_id,
                 solver_cfg_id: cfg_id,
                 cpu_timeout_s: 10,
                 timeout_ms: 240_000
               )
    end
  end

  # A `.tgz` with one configuration, `bin/starexec_run_default`, that answers
  # Theorem for any benchmark — enough to exercise upload, configuration
  # discovery and the job pipeline without a real prover in the archive.
  defp solver_archive(name) do
    dir = Path.join(System.tmp_dir!(), name)
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    script = Path.join(bin, "starexec_run_default")
    File.write!(script, "#!/bin/sh\necho \"% SZS status Theorem for $(basename \"$1\")\"\n")
    File.chmod!(script, 0o755)

    archive = Path.join(System.tmp_dir!(), name <> ".tgz")

    :ok =
      :erl_tar.create(
        String.to_charlist(archive),
        [{~c"bin", String.to_charlist(bin)}],
        [:compressed]
      )

    File.rm_rf!(dir)
    on_exit(fn -> File.rm(archive) end)
    archive
  end

  defp require_env(nil, name), do: raise("#{name} must be set for the StarExec live tests")
  defp require_env(value, _name), do: value
end
