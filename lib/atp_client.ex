defmodule AtpClient do
  @moduledoc """
  Elixir client for external automated theorem provers.

  Four backends are supported:

    * **SystemOnTPTP** — public tptp.org HTTP form API; see
      `AtpClient.SystemOnTptp`.
    * **StarExec** — self-hosted StarExec instances; see `AtpClient.StarExec`.
    * **Isabelle** — `isabelle server` instances via `isabelle_elixir`; see
      `AtpClient.Isabelle`.
    * **LocalExec** — a locally installed TPTP-compliant prover binary
      (e.g. E, Vampire) invoked via `Port.open/2`; see `AtpClient.LocalExec`.
      Run `scripts/build_eprover.sh` to install E into `priv/bin/`.

  Each backend implements `AtpClient.Backend`: `query/2` takes an
  `AtpClient.Input` and returns `{:ok, %AtpClient.Result{}}` or
  `{:error, reason}`.

  ## Problems and results

  A problem is a binary, a `Tptp.File` or a `Tptp.Unit`; see `AtpClient.Input`
  for what each sends. A backend never parses what it sends. `preflight/1` is
  the explicit check for callers who want one — an editor, say — before a
  round-trip to a prover.

  A result's `status` is a value of `Tptp.Szs.Ontology`, read from the system's
  output by `AtpClient.Verdict`; see `AtpClient.Result` for the rest of what it
  carries.

      {:ok, result} = AtpClient.LocalExec.query("fof(c, conjecture, $true).", binary: "eprover")
      result.status      # :theorem
      result.evidence    # :szs
      result.output      # E's stdout

  ## Configuration

  Settings are resolved from three sources, in increasing precedence:

  1. Library defaults (declared in `AtpClient`'s `mix.exs`).
  2. Application environment (typically `config/config.exs`).
  3. Per-call keyword options passed to the relevant function.

  Only the settings required by the backends you actually use need to be set.

      # config/config.exs
      import Config

      config :atp_client, :sotptp,
        # The default points at tptp.org; override for a mirror or internal
        # deployment:
        url: "https://tptp.org/cgi-bin/SystemOnTPTPFormReply",
        default_time_limit_sec: 10

      config :atp_client, :starexec,
        base_url: "https://starexec.example.org/starexec",
        username: System.get_env("STAREXEC_USER"),
        password: System.get_env("STAREXEC_PASS")

      config :atp_client, :isabelle,
        host: "isabelle.example.org",
        port: 9999,
        password: System.get_env("ISABELLE_PASSWORD"),
        session: "HOL"

      # Same-host setups need nothing more — `:local_dir` defaults to a
      # subdirectory of `System.tmp_dir!/0`. Only set `:local_dir` and
      # `:isabelle_dir` when the two sides see the directory under different
      # paths (containers, Cygwin).

      config :atp_client, :local_exec,
        binary: "eprover",
        args: ["--auto", "--tstp-format", "--cpu-limit=10"],
        cpu_timeout_s: 10

  Any setting may be overridden for a single call:

      AtpClient.LocalExec.query(problem, binary: "vampire", args: ["--mode", "casc"])
  """

  alias AtpClient.Input
  alias AtpClient.Result

  @backends [
    AtpClient.SystemOnTptp,
    AtpClient.StarExec,
    AtpClient.Isabelle,
    AtpClient.LocalExec
  ]

  @doc """
  Returns the modules implementing `AtpClient.Backend`. Iterate this in a
  configuration UI to discover what's wireable without hard-coding the list.
  """
  @spec backends() :: [module()]
  def backends, do: @backends

  @doc """
  Runs `problem` on `backend`, optionally checking it first.

  Equivalent to `backend.query(problem, opts)` with one option of its own:

    * `:preflight` — when `true`, `preflight/1` runs first and an invalid
      problem is `{:error, {:invalid_problem, diagnostics}}` without any
      round-trip. Defaults to `false`: the direct path parses nothing.

      AtpClient.query(AtpClient.SystemOnTptp, problem, preflight: true, time_limit_sec: 10)
  """
  @spec query(module(), Input.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def query(backend, problem, opts \\ []) when is_atom(backend) and is_list(opts) do
    case Keyword.pop(opts, :preflight, false) do
      {true, opts} ->
        with :ok <- preflight(problem), do: backend.query(problem, opts)

      {_false, opts} ->
        backend.query(problem, opts)
    end
  end

  @doc """
  Reads and lints the problem with `Tptp.analyze/2`, without sending it anywhere.

  A `Tptp.File` or `Tptp.Unit` is analysed as it is; anything else is parsed
  from its bytes first. Returns `:ok` when no diagnostic is an error, and
  `{:error, {:invalid_problem, diagnostics}}` with every diagnostic, warnings
  included, otherwise. The analysis costs what `Tptp.analyze/2` costs — a
  traversal, and for a binary a parse — which is why no backend does it on
  its own.

      iex> AtpClient.preflight("fof(a, axiom, p).")
      :ok

      iex> {:error, {:invalid_problem, diagnostics}} = AtpClient.preflight("fof(a, axiom, p")
      iex> Tptp.Diagnostic.any_errors?(diagnostics)
      true
  """
  @spec preflight(Input.t()) :: :ok | {:error, {:invalid_problem, [Tptp.Diagnostic.t()]}}
  def preflight(problem) do
    %Tptp.Analysis{diagnostics: diagnostics} = Tptp.analyze(subject(problem))

    if Tptp.Diagnostic.any_errors?(diagnostics) do
      {:error, {:invalid_problem, diagnostics}}
    else
      :ok
    end
  end

  @doc """
  Verifies a solution through a SystemOnTPTP verifier.

  `subject` is a `Tptp.Derivation`, an `AtpClient.Interpretation`, or a
  `%AtpClient.Result{}`, whose `AtpClient.Result.derivation/1` is taken, else
  its `AtpClient.Result.interpretation/1`. It is sent to
  `AtpClient.SystemOnTptp.process_solution/3`.

  ## Options

    * `:with` — the verifier, a SystemOnTPTP system name or identifier. Default
      `"GDV"` for a derivation and `"AGMV"` for an interpretation.

  Every other option goes to `process_solution/3`. `AtpClient.Result.success?/1`
  is true of the result for `VerifiedGood` (AGMV's `Verified` is read as that,
  through its own `Solved` pattern).

  Returns `{:error, :nothing_to_verify}` for a result with neither a derivation
  nor an interpretation, and the reading's error for one whose derivation or
  interpretation does not read.

      {:ok, result} = AtpClient.SystemOnTptp.query_system(problem, "E")
      {:ok, verdict} = AtpClient.verify(result)
      verdict.status  # => :verified_good
  """
  @spec verify(Tptp.Derivation.t() | AtpClient.Interpretation.t() | Result.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def verify(subject, opts \\ [])

  def verify(%Result{} = result, opts) do
    case Result.derivation(result) do
      {:ok, derivation, _diagnostics} ->
        verify(derivation, opts)

      {:error, _} = error ->
        error

      :none ->
        case Result.interpretation(result) do
          {:ok, interpretation, _diagnostics} -> verify(interpretation, opts)
          {:error, _} = error -> error
          :none -> {:error, :nothing_to_verify}
        end
    end
  end

  def verify(%Tptp.Derivation{} = derivation, opts), do: verify_with(derivation, "GDV", opts)

  def verify(%AtpClient.Interpretation{} = interpretation, opts),
    do: verify_with(interpretation, "AGMV", opts)

  defp verify_with(subject, default, opts) do
    {verifier, opts} = Keyword.pop(opts, :with, default)
    AtpClient.SystemOnTptp.process_solution(subject, verifier, opts)
  end

  @spec subject(Input.t()) :: binary() | Tptp.File.t() | Tptp.Unit.t()
  defp subject(%Tptp.File{} = file), do: file
  defp subject(%Tptp.Unit{} = unit), do: unit
  defp subject(problem), do: problem |> Input.to_iodata() |> IO.iodata_to_binary()
end
