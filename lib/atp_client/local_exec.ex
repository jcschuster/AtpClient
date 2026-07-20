defmodule AtpClient.LocalExec do
  @moduledoc """
  Backend that invokes a locally installed, TPTP-compliant prover via
  `Port.open/2` and normalizes its stdout through
  `AtpClient.ResultNormalization.interpret_result/1`.

  No authentication, no polling: the prover runs to completion (or until one of
  the two timeouts fires) and the captured stdout is classified by the same
  SZS-aware classifier used for the SystemOnTPTP and StarExec backends.

  ## Cancellation

  The prover is run through a port owned by the calling process. On port
  close, the BEAM closes stdio pipes but does **not** signal the OS child.
  A guardian process monitors the caller and issues SIGKILL to the OS child
  if the caller dies (`Process.exit/2`, `Task.shutdown/2`, or any other
  linked termination) before the prover returns. The wall-clock timeout uses
  the same mechanism.

  Process-group cleanup is **not** performed: SIGKILL reaches only the direct
  child, so a prover that forks helper subprocesses may leak them. This is
  rare in the TPTP ecosystem and is left for a follow-up.

  ## Two-layered timeout

  Two independent timeouts protect the caller from a wedged prover:

    * The **prover-side CPU limit** (`:cpu_timeout_s`) is passed to the prover
      via the configured `:args`. A prover that honors it (E's `--cpu-limit`,
      Vampire's `-t`, …) will exit cleanly and emit a real SZS status line
      — the classifier maps e.g. `SZS status Timeout` to `{:ok, :timeout}`
      and `SZS status MemoryOut` to `{:ok, :memory_out}`. The status atom
      reflects what the prover reported, not a generic timeout.
    * The **wall-clock timeout** (`:wall_timeout_ms`) is enforced on the BEAM
      side: when it fires, the guardian sends SIGKILL to the OS child and the
      result is normalised to `{:ok, :timeout}` — the wall-clock kill does not
      produce a prover SZS line, so only `:timeout` can be returned on that
      path.

  By default `:wall_timeout_ms` is `(cpu_timeout_s + 10) * 1000`, leaving the
  prover ten extra seconds to flush its `SZS status` line before the kill.

  ## Configuration

      config :atp_client, :local_exec,
        binary: "eprover",       # required; resolved with System.find_executable/1
        args: ["--auto", "--tstp-format"],
        cpu_timeout_s: 30,
        wall_timeout_ms: 45_000  # optional; computed from cpu_timeout_s if unset

  Any setting may be overridden per call:

      AtpClient.LocalExec.query(problem, binary: "vampire", args: ["--mode", "casc"])

  Absolute paths are accepted verbatim; otherwise the binary is looked up on
  `PATH` via `System.find_executable/1` and `{:error, {:prover_not_found, name}}`
  is returned when missing.

  ## Building the args

  `LocalExec` appends the problem file path as the **last** positional argument
  to the configured `:args`. Provers that take the file path elsewhere should
  embed the literal `"{{problem}}"` placeholder in `:args`; it is substituted
  with the temp file path before invocation and suppresses the default append.

      args: ["--input-file={{problem}}", "--cpu-limit=60"]
  """

  @behaviour AtpClient.Backend

  alias AtpClient.{Config, ResultNormalization}
  alias AtpClient.Config.Field

  # `:args` is validated as a list of strings only — the *contents* are
  # prover-specific flags (E's `--cpu-limit`, Vampire's `--time_limit`, …)
  # that LocalExec deliberately does not parse. See the module doc.
  @verify_opts_schema NimbleOptions.new!(binary: [type: :string])

  @query_opts_schema NimbleOptions.new!(
                       binary: [type: :string],
                       args: [type: {:list, :string}],
                       cpu_timeout_s: [type: :non_neg_integer],
                       wall_timeout_ms: [type: :non_neg_integer],
                       raw: [type: :boolean]
                     )

  @impl AtpClient.Backend
  def config_key, do: :local_exec

  @impl AtpClient.Backend
  def label, do: "Local prover"

  @impl AtpClient.Backend
  def config_schema do
    [
      %Field{
        key: :binary,
        type: :string,
        required?: true,
        group: :connection,
        label: "Prover binary",
        doc: "Name (looked up on $PATH) or absolute path."
      },
      %Field{
        key: :args,
        type: :string_list,
        required?: false,
        group: :defaults,
        default: [],
        label: "Default arguments",
        doc: ~s|Use "{{problem}}" to pin the problem file's position.|
      },
      %Field{
        key: :cpu_timeout_s,
        type: :integer,
        required?: false,
        group: :defaults,
        default: 60,
        label: "CPU timeout (s)"
      },
      %Field{
        key: :wall_timeout_ms,
        type: :integer,
        required?: false,
        group: :defaults,
        label: "Wall-clock timeout (ms)",
        doc: "Defaults to (cpu_timeout_s + 10) * 1000 when blank."
      }
    ]
  end

  @impl AtpClient.Backend
  def verify(opts \\ []) do
    NimbleOptions.validate!(opts, @verify_opts_schema)
    binary = Config.fetch!(:local_exec, :binary, opts)

    case resolve(binary) do
      {:ok, _path} -> :ok
      {:error, _} = err -> err
    end
  end

  @typedoc """
  Same as `t:AtpClient.ResultNormalization.atp_result/0`, with one extra
  failure shape specific to `LocalExec`:

    * `{:error, {:prover_not_found, name}}` — `System.find_executable/1`
      returned `nil` for the configured `:binary`.

  Both the prover-side CPU limit and the BEAM-side wall-clock kill surface
  as `{:ok, :timeout}`; see "Two-layered timeout" in the module doc.
  """
  @type result :: ResultNormalization.atp_result() | {:error, term()}

  @placeholder "{{problem}}"

  @doc """
  Runs the configured prover against `problem` (a TPTP problem in a string)
  and returns the normalized result.

  See the module doc for the option list. All keys may also be set per-call:

    * `:binary` (required) — the prover executable name or an absolute path;
    * `:args` — extra arguments to pass before the problem file path
      (default `[]`). Embed `"{{problem}}"` to control where the file path is
      inserted; otherwise it is appended last;
    * `:cpu_timeout_s` — CPU limit hint reported to callers and used to derive
      the default wall-clock timeout (default `60`). `LocalExec` does **not**
      inject a `--cpu-limit` flag for you — encode that in `:args` so each
      prover gets the flag spelling it understands;
    * `:wall_timeout_ms` — BEAM-side wall-clock kill (default
      `(cpu_timeout_s + 10) * 1000`);
    * `:raw` — when `true`, skip `interpret_result/1` and return
      `{:ok, captured_stdout}` so the caller can inspect the prover's raw
      output. The `AtpClient.Backend` behaviour's `query/2` entry point always
      passes `raw: false` so the unified contract always returns an
      `atp_result()`.
  """
  @impl AtpClient.Backend
  @spec query(String.t(), keyword()) :: result()
  def query(problem, opts \\ []) when is_binary(problem) do
    NimbleOptions.validate!(opts, @query_opts_schema)
    binary = Config.fetch!(:local_exec, :binary, opts)
    args = Config.fetch(:local_exec, :args, [], opts)
    cpu_s = Config.fetch(:local_exec, :cpu_timeout_s, 60, opts)
    raw = Keyword.get(opts, :raw, false)

    wall_ms =
      case Config.fetch(:local_exec, :wall_timeout_ms, nil, opts) do
        nil -> (cpu_s + 10) * 1000
        ms -> ms
      end

    with {:ok, exe} <- resolve(binary),
         {:ok, problem_path} <- write_temp(problem) do
      try do
        full_args = build_args(args, problem_path)
        {:ok, output} = run(exe, full_args, wall_ms)
        if raw, do: {:ok, output}, else: ResultNormalization.interpret_result(output)
      after
        _ = File.rm(problem_path)
      end
    end
  end

  defp resolve(binary) when is_binary(binary) do
    case Path.type(binary) do
      :absolute -> resolve_absolute(binary)
      _ -> resolve_on_path(binary)
    end
  end

  defp resolve_absolute(path) do
    if File.regular?(path),
      do: {:ok, path},
      else: {:error, {:prover_not_found, path}}
  end

  defp resolve_on_path(name) do
    case System.find_executable(name) do
      nil -> {:error, {:prover_not_found, name}}
      exe -> {:ok, exe}
    end
  end

  defp write_temp(problem) do
    dir = System.tmp_dir!()
    name = "atp_client_localexec_#{System.unique_integer([:positive])}_#{:os.getpid()}.p"
    path = Path.join(dir, name)

    case File.write(path, problem) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:tempfile, reason}}
    end
  end

  defp build_args(args, problem_path) do
    if @placeholder in args do
      Enum.map(args, fn
        @placeholder -> problem_path
        other -> other
      end)
    else
      args ++ [problem_path]
    end
  end

  # Runs the prover under a port owned by the calling process and a small
  # guardian process linked to the caller. `stderr_to_stdout`: prover
  # diagnostics and SZS status lines both end up in the same stream so the
  # classifier sees everything.
  #
  # On Linux/macOS, Port.close only closes stdio pipes; it does not signal
  # the OS child. To get true death-as-cancellation we (a) explicitly
  # SIGKILL the os_pid on wall-clock timeout, and (b) keep a guardian
  # process that monitors the caller and SIGKILLs the os_pid if the caller
  # dies (Process.exit, Task.shutdown, …) before the prover returns.
  defp run(exe, args, wall_ms) do
    port =
      Port.open(
        {:spawn_executable, exe},
        [:binary, :exit_status, :hide, :stderr_to_stdout, {:args, args}]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    guardian = start_guardian(os_pid)
    deadline = System.monotonic_time(:millisecond) + wall_ms

    try do
      collect(port, deadline, [], os_pid)
    after
      stop_guardian(guardian)
    end
  end

  defp collect(port, deadline, acc, os_pid) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        collect(port, deadline, [acc, chunk], os_pid)

      {^port, {:exit_status, _code}} ->
        # Non-zero exit is normal for many provers (E exits 1 on Timeout, etc.);
        # the SZS classifier on stdout is what matters.
        {:ok, IO.iodata_to_binary(acc)}
    after
      remaining ->
        sigkill(os_pid)
        close_port(port)
        # Fold into the same :timeout the classifier emits for a clean
        # prover-reported Timeout — synthesise an SZS line so the result
        # flows through the same funnel.
        {:ok, "% SZS status Timeout (wall-clock kill by AtpClient.LocalExec)"}
    end
  end

  defp start_guardian(nil), do: nil

  defp start_guardian(os_pid) do
    caller = self()

    spawn(fn ->
      ref = Process.monitor(caller)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> sigkill(os_pid)
        :stop -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  defp stop_guardian(nil), do: :ok
  defp stop_guardian(pid), do: send(pid, :stop)

  defp sigkill(nil), do: :ok

  defp sigkill(os_pid) when is_integer(os_pid) do
    # The OS child may already have exited by the time we get here; kill -KILL
    # against a non-existent pid is harmless and we ignore its result.
    _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  # Port.close/1 raises ArgumentError if the runtime has already torn the port
  # down; treat that as success.
  defp close_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain_port_messages(port)
  end

  defp drain_port_messages(port) do
    receive do
      {^port, _} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end
end
