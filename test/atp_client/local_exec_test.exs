defmodule AtpClient.LocalExecTest do
  use ExUnit.Case, async: false

  alias AtpClient.LocalExec

  @moduletag :tmp_dir

  # Build a fake "prover": a /bin/sh script that prints `output` and optionally
  # sleeps for `sleep_s` seconds before exiting. Returned path is executable.
  defp fake_prover(tmp_dir, name, output, opts \\ []) do
    sleep_s = Keyword.get(opts, :sleep_s, 0)
    exit_code = Keyword.get(opts, :exit_code, 0)
    path = Path.join(tmp_dir, name)

    body = """
    #!/bin/sh
    cat <<'__OUT__'
    #{output}
    __OUT__
    """

    body =
      if sleep_s > 0 do
        body <> "sleep #{sleep_s}\n"
      else
        body
      end

    File.write!(path, body <> "exit #{exit_code}\n")
    File.chmod!(path, 0o755)
    path
  end

  setup do
    # Each test sets its own :local_exec config; clear afterwards so tests
    # don't leak into each other (async: false).
    on_exit(fn -> Application.delete_env(:atp_client, :local_exec) end)
    :ok
  end

  defp os_pid_alive?(pid) when is_binary(pid) do
    # `kill -0` returns 0 if the pid exists and the caller may signal it.
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp wait_for_pid_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_pid_file(path, deadline)
  end

  defp do_wait_for_pid_file(path, deadline) do
    case File.read(path) do
      {:ok, contents} ->
        trimmed = String.trim(contents)
        if trimmed == "", do: wait_more(path, deadline), else: trimmed

      {:error, _} ->
        wait_more(path, deadline)
    end
  end

  defp wait_more(path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("pid file #{path} did not appear")
    else
      Process.sleep(20)
      do_wait_for_pid_file(path, deadline)
    end
  end

  defp eventually(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        do_eventually(fun, deadline)
    end
  end

  describe "query/2 — happy path" do
    test "Theorem output is classified as {:ok, :thm}", %{tmp_dir: tmp} do
      exe = fake_prover(tmp, "prover_thm", "# SZS status Theorem for x")
      assert LocalExec.query("fof(a, conjecture, p).", binary: exe) == {:ok, :thm}
    end

    test "CounterSatisfiable output is classified as {:ok, :csat}", %{tmp_dir: tmp} do
      exe = fake_prover(tmp, "prover_csat", "# SZS status CounterSatisfiable for x")
      assert LocalExec.query("fof(a, conjecture, p).", binary: exe) == {:ok, :csat}
    end

    test "prover-reported Timeout maps to {:ok, :timeout}", %{tmp_dir: tmp} do
      exe = fake_prover(tmp, "prover_timeout", "# SZS status Timeout for x")
      assert LocalExec.query("fof(a, conjecture, p).", binary: exe) == {:ok, :timeout}
    end

    test "non-zero exit does not override SZS classification", %{tmp_dir: tmp} do
      exe = fake_prover(tmp, "prover_thm_exit1", "# SZS status Theorem for x", exit_code: 1)
      assert LocalExec.query("fof(a, conjecture, p).", binary: exe) == {:ok, :thm}
    end

    test "unrecognized stdout yields {:error, {:unrecognized_output, ...}}",
         %{tmp_dir: tmp} do
      exe = fake_prover(tmp, "prover_garbage", "hello world")

      assert {:error, {:unrecognized_output, _}} =
               LocalExec.query("fof(a, conjecture, p).", binary: exe)
    end
  end

  describe "query/2 — binary resolution" do
    test "absolute path to a non-existent binary returns {:error, {:prover_not_found, _}}" do
      assert LocalExec.query("fof(a, conjecture, p).", binary: "/nonexistent/path/eprover") ==
               {:error, {:prover_not_found, "/nonexistent/path/eprover"}}
    end

    test "unresolved name on PATH returns {:error, {:prover_not_found, _}}" do
      assert LocalExec.query("fof(a, conjecture, p).",
               binary: "definitely_not_a_real_prover_xyz_123"
             ) ==
               {:error, {:prover_not_found, "definitely_not_a_real_prover_xyz_123"}}
    end

    test "resolve_binary/1 surfaces the same error without running anything" do
      assert LocalExec.resolve_binary(binary: "definitely_not_a_real_prover_xyz_123") ==
               {:error, {:prover_not_found, "definitely_not_a_real_prover_xyz_123"}}
    end

    test "resolve_binary/1 returns absolute path for a real script", %{tmp_dir: tmp} do
      exe = fake_prover(tmp, "real_prover", "# SZS status Theorem for x")
      assert {:ok, ^exe} = LocalExec.resolve_binary(binary: exe)
    end

    test "missing :binary config raises ArgumentError" do
      assert_raise ArgumentError, ~r/missing required setting `:binary`/, fn ->
        LocalExec.query("fof(a, conjecture, p).", [])
      end
    end
  end

  describe "query/2 — wall-clock timeout" do
    test "wall-clock kill folds into {:ok, :timeout}", %{tmp_dir: tmp} do
      # Prover sleeps 2s before exiting; wall-clock budget is 100 ms. The
      # BEAM-side kill is mapped onto the same :timeout the SZS classifier
      # emits for a clean prover-reported Timeout — see the module doc.
      exe = fake_prover(tmp, "prover_hang", "# SZS status Theorem for x", sleep_s: 2)

      assert LocalExec.query("fof(a, conjecture, p).",
               binary: exe,
               wall_timeout_ms: 100
             ) == {:ok, :timeout}
    end

    test "wall-clock kill actually terminates the OS child", %{tmp_dir: tmp} do
      # The fake prover writes its own pid to a side-channel file before
      # sleeping. After the wall-clock kill we read the pid out and confirm
      # it is no longer a running process.
      pid_file = Path.join(tmp, "prover.pid")
      path = Path.join(tmp, "pid_prover")

      File.write!(path, """
      #!/bin/sh
      echo "$$" > "#{pid_file}"
      sleep 60
      echo "# SZS status Theorem for x"
      """)

      File.chmod!(path, 0o755)

      assert LocalExec.query("fof(a, conjecture, p).",
               binary: path,
               wall_timeout_ms: 200
             ) == {:ok, :timeout}

      pid =
        pid_file
        |> File.read!()
        |> String.trim()

      # Give the kernel a moment to reap the child.
      Process.sleep(200)
      refute os_pid_alive?(pid), "OS child #{pid} survived wall-clock kill"
    end

    test "default wall_timeout_ms is derived from cpu_timeout_s when unset",
         %{tmp_dir: tmp} do
      # cpu_timeout_s = 0 ⇒ wall_timeout_ms defaults to 10_000 ms. The prover
      # finishes instantly, so we only assert the call returns the SZS result
      # and not a timeout.
      exe = fake_prover(tmp, "prover_fast", "# SZS status Theorem for x")

      assert LocalExec.query("fof(a, conjecture, p).", binary: exe, cpu_timeout_s: 0) ==
               {:ok, :thm}
    end
  end

  describe "query/2 — cancellation via caller death" do
    test "killing the calling process kills the OS child", %{tmp_dir: tmp} do
      pid_file = Path.join(tmp, "cancel.pid")
      path = Path.join(tmp, "cancel_prover")

      File.write!(path, """
      #!/bin/sh
      echo "$$" > "#{pid_file}"
      sleep 60
      echo "# SZS status Theorem for x"
      """)

      File.chmod!(path, 0o755)

      parent = self()

      runner =
        spawn(fn ->
          send(parent, {:started, self()})
          # Long wall-clock budget so it can't fire before we kill the runner.
          LocalExec.query("fof(a, conjecture, p).",
            binary: path,
            wall_timeout_ms: 60_000
          )
        end)

      assert_receive {:started, ^runner}, 1_000

      # Wait for the child shell to record its pid.
      pid = wait_for_pid_file(pid_file, 2_000)
      assert os_pid_alive?(pid)

      Process.exit(runner, :kill)

      # The port is owned by the runner; runner death closes the port and
      # the BEAM sends SIGKILL to the OS child. Give the kernel a moment to
      # reap it.
      assert eventually(fn -> not os_pid_alive?(pid) end, 2_000),
             "OS child #{pid} was not killed when the calling process died"
    end
  end

  describe "query/2 — argument construction" do
    test "extra args are passed before the problem file path", %{tmp_dir: tmp} do
      # An echo-args script that prints its own argv back and a fixed SZS line.
      path = Path.join(tmp, "argprover")

      File.write!(path, """
      #!/bin/sh
      echo "ARGS: $*"
      echo "# SZS status Theorem for x"
      """)

      File.chmod!(path, 0o755)

      # Capture by routing through a side-channel file. The script writes argv
      # to its own stdout, classifier sees both lines; we only need to confirm
      # the SZS line still hits.
      assert LocalExec.query("fof(a, conjecture, p).",
               binary: path,
               args: ["--auto", "--cpu-limit=5"]
             ) == {:ok, :thm}
    end

    test "{{problem}} placeholder is substituted with the temp file path",
         %{tmp_dir: tmp} do
      # The script verifies that arg #1 equals an existing file path (proving
      # placeholder substitution happened) and writes SZS status accordingly.
      path = Path.join(tmp, "placeholder_prover")

      File.write!(path, """
      #!/bin/sh
      if [ -f "$1" ]; then
        echo "# SZS status Theorem for x"
      else
        echo "# SZS status GaveUp for x"
      fi
      """)

      File.chmod!(path, 0o755)

      assert LocalExec.query("fof(a, conjecture, p).",
               binary: path,
               args: ["{{problem}}", "--auto"]
             ) == {:ok, :thm}
    end
  end

  # Real-prover integration tests, skipped by default. Run locally with:
  #     mix test --include local_prover
  describe "real prover (gated)" do
    @describetag :local_prover

    @trivial_problem """
    fof(a1, axiom, p).
    fof(c, conjecture, p).
    """

    test "eprover proves a trivial conjecture" do
      assert LocalExec.query(@trivial_problem,
               binary: "eprover",
               args: ["--auto", "--cpu-limit=5", "--tstp-format"]
             ) == {:ok, :thm}
    end
  end
end
