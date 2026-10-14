defmodule AtpClient.LocalExec do
  @moduledoc """
  Backend that invokes a locally installed, TPTP-compliant prover via
  `Port.open/2` and reads its stdout through `AtpClient.Verdict`.

  No authentication, no polling: the prover runs to completion (or until one of
  the two timeouts fires) and the captured stdout is read by the same SZS reader
  used for the SystemOnTPTP and StarExec backends.

  ## Two ways in

  `query/2` takes an `AtpClient.Input`, writes its bytes to a temporary file
  and passes that to the prover. `query_file/2` takes a path and passes it to the
  prover as it is: nothing is read or copied, and the prover resolves the file's
  `include` directives itself, against the file's directory and `$TPTP`.

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
      result is `:timeout`. The prover printed no status line on that path, so
      the backend appends one of its own, `% SZS status Timeout : wall-clock kill
      by AtpClient.LocalExec`, which the result's `output` and `comment` carry.

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

  alias AtpClient.Config
  alias AtpClient.Config.Field
  alias AtpClient.Input
  alias AtpClient.Result
  alias AtpClient.SystemOnTptp.Systems
  alias AtpClient.Verdict

  # `:args` is validated as a list of strings only — the *contents* are
  # prover-specific flags (E's `--cpu-limit`, Vampire's `--time_limit`, …)
  # that LocalExec deliberately does not parse. See the module doc.
  @verify_opts_schema NimbleOptions.new!(binary: [type: :string])

  @query_opts_schema NimbleOptions.new!(
                       binary: [type: :string],
                       args: [type: {:list, :string}],
                       cpu_timeout_s: [type: :non_neg_integer],
                       wall_timeout_ms: [type: :non_neg_integer],
                       system: [type: :string]
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
  What `query/2` and `query_file/2` return.

    * `{:ok, %AtpClient.Result{}}` — the prover ran and asserted a status. Both
      the prover-side CPU limit and the BEAM-side wall-clock kill arrive here as
      `:timeout`; see "Two-layered timeout" in the module doc.
    * `{:error, {:prover_not_found, name}}` — `System.find_executable/1`
      returned `nil` for the configured `:binary`.
    * `{:error, {:tempfile, reason}}` — the problem could not be written.
    * `{:error, reason}` from `t:AtpClient.Verdict.failure/0` — the prover ran
      but its output carries no status the reader recognises.
  """
  @type result :: {:ok, Result.t()} | {:error, term()}

  @placeholder "{{problem}}"

  @doc """
  Runs the configured prover against `problem` and reads the result.

  The problem's bytes are written to a temporary file, which is removed after the
  run. See the module doc for the option list. All keys may also be set per-call:

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
    * `:system` — a SystemOnTPTP system name or identifier (`"AGMV"`) whose
      record's `Solved` patterns read the output, for a binary that prints a
      verdict outside the SZS ontology the way that system does; see
      `AtpClient.Verdict`. Looked up in `AtpClient.SystemOnTptp.Systems`. It
      also picks the prover-specific messages read (`AtpClient.Verdict.patterns/1`),
      which otherwise follow the binary's name — set it for a wrapper script.
  """
  @impl AtpClient.Backend
  @spec query(Input.t(), keyword()) :: result()
  def query(problem, opts \\ []) do
    NimbleOptions.validate!(opts, @query_opts_schema)

    with {:ok, binary, exe} <- executable(opts),
         {:ok, problem_path} <- write_temp(Input.to_iodata(problem)) do
      try do
        run_file(problem_path, binary, exe, opts)
      after
        _ = File.rm(problem_path)
      end
    end
  end

  @doc """
  Runs the configured prover against the problem file at `path` and reads the
  result.

  The path is handed to the prover unchanged: the file is neither read nor
  copied, and `include` directives in it are the prover's to resolve. Takes the
  same options as `query/2`.
  """
  @spec query_file(Path.t(), keyword()) :: result()
  def query_file(path, opts \\ []) when is_binary(path) do
    NimbleOptions.validate!(opts, @query_opts_schema)

    with {:ok, binary, exe} <- executable(opts) do
      run_file(path, binary, exe, opts)
    end
  end

  @spec executable(keyword()) ::
          {:ok, binary(), Path.t()} | {:error, {:prover_not_found, binary()}}
  defp executable(opts) do
    binary = Config.fetch!(:local_exec, :binary, opts)

    with {:ok, exe} <- resolve(binary), do: {:ok, binary, exe}
  end

  @spec run_file(Path.t(), binary(), Path.t(), keyword()) :: result()
  defp run_file(path, binary, exe, opts) do
    args = Config.fetch(:local_exec, :args, [], opts)
    cpu_s = Config.fetch(:local_exec, :cpu_timeout_s, 60, opts)

    wall_ms =
      case Config.fetch(:local_exec, :wall_timeout_ms, nil, opts) do
        nil -> (cpu_s + 10) * 1000
        ms -> ms
      end

    {:ok, output} = run(exe, build_args(args, path), wall_ms)

    Verdict.interpret(
      output,
      __MODULE__,
      [system: binary] ++ Systems.verdict_options(opts[:system])
    )
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

  defp write_temp(iodata) do
    dir = System.tmp_dir!()
    name = "atp_client_localexec_#{System.unique_integer([:positive])}_#{:os.getpid()}.p"
    path = Path.join(dir, name)

    case File.write(path, iodata) do
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
        # the status line on stdout is what matters.
        {:ok, IO.iodata_to_binary(acc)}
    after
      remaining ->
        sigkill(os_pid)
        close_port(port)
        # The prover printed no status; append one so the result flows
        # through the same reader as a prover-reported Timeout, with the
        # output the prover did manage to print kept ahead of it.
        line = Tptp.Szs.status_line(:timeout, nil, "wall-clock kill by AtpClient.LocalExec")
        {:ok, IO.iodata_to_binary([acc, ?\n, line, ?\n])}
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
