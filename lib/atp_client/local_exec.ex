defmodule AtpClient.LocalExec do
  @moduledoc """
  Backend that invokes a locally installed, TPTP-compliant prover via
  `System.cmd/3` and normalizes its stdout through
  `AtpClient.ResultNormalization.interpret_result/1`.

  No authentication, no polling: the prover runs to completion (or until one of
  the two timeouts fires) and the captured stdout is classified by the same
  SZS-aware classifier used for the SystemOnTPTP and StarExec backends.

  ## Two-layered timeout

  Two timeouts protect the caller from a wedged prover, and both fold into the
  same `{:ok, :timeout}` result so callers do not have to branch on the
  failure mode:

    * The **prover-side CPU limit** (`:cpu_timeout_s`) is passed to the prover
      via the configured `:args`. A prover that honors it (E's `--cpu-limit`,
      Vampire's `-t`, …) will exit cleanly and emit a real
      `SZS status Timeout` or `SZS status ResourceOut` — the classifier maps
      both to `{:ok, :timeout}` / `{:ok, :out_of_resources}`.
    * The **wall-clock timeout** (`:wall_timeout_ms`) is enforced on the BEAM
      side: the prover runs inside a `Task` guarded by `Task.yield/2` plus
      `Task.shutdown/2`. When this fires (because the prover ignored the CPU
      limit, hung, or never honored signals), the kill is mapped to the same
      `{:ok, :timeout}`.

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

  alias AtpClient.{Config, ResultNormalization}

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
      `(cpu_timeout_s + 10) * 1000`).
  """
  @spec query(String.t(), keyword()) :: result()
  def query(problem, opts \\ []) when is_binary(problem) do
    binary = Config.fetch!(:local_exec, :binary, opts)
    args = Config.fetch(:local_exec, :args, [], opts)
    cpu_s = Config.fetch(:local_exec, :cpu_timeout_s, 60, opts)

    wall_ms =
      case Config.fetch(:local_exec, :wall_timeout_ms, nil, opts) do
        nil -> (cpu_s + 10) * 1000
        ms -> ms
      end

    with {:ok, exe} <- resolve(binary),
         {:ok, problem_path} <- write_temp(problem) do
      try do
        full_args = build_args(args, problem_path)

        case run(exe, full_args, wall_ms) do
          {:ok, output} -> ResultNormalization.interpret_result(output)
          {:error, _} = err -> err
        end
      after
        _ = File.rm(problem_path)
      end
    end
  end

  @doc """
  Returns the absolute path of the configured prover binary, or
  `{:error, {:prover_not_found, name}}` if it can't be located.

  Useful in startup checks and for surfacing a clear error before the first
  `query/2` call.
  """
  @spec resolve_binary(keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_binary(opts \\ []) do
    binary = Config.fetch!(:local_exec, :binary, opts)
    resolve(binary)
  end

  defp resolve(binary) when is_binary(binary) do
    cond do
      Path.type(binary) == :absolute and File.regular?(binary) ->
        {:ok, binary}

      Path.type(binary) == :absolute ->
        {:error, {:prover_not_found, binary}}

      exe = System.find_executable(binary) ->
        {:ok, exe}

      true ->
        {:error, {:prover_not_found, binary}}
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
    if Enum.any?(args, &(&1 == @placeholder)) do
      Enum.map(args, fn
        @placeholder -> problem_path
        other -> other
      end)
    else
      args ++ [problem_path]
    end
  end

  defp run(exe, args, wall_ms) do
    task =
      Task.async(fn ->
        # stderr_to_stdout: prover diagnostics and SZS status lines both end up
        # in the same stream so the classifier sees everything.
        System.cmd(exe, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, wall_ms) || Task.shutdown(task, :brutal_kill) do
      # Non-zero exit is normal for many provers (E exits 1 on Timeout, etc.);
      # the SZS classifier on stdout is what matters.
      {:ok, {output, _exit_status}} -> {:ok, output}
      # Wall-clock kill folds into the same :timeout the classifier emits for
      # a clean prover-reported Timeout — synthesize an SZS line so the result
      # flows through the same funnel.
      nil -> {:ok, "% SZS status Timeout (wall-clock kill by AtpClient.LocalExec)"}
      {:exit, reason} -> {:error, {:prover_crashed, reason}}
    end
  end
end
