defmodule AtpClient.Verdict do
  @moduledoc """
  Reads a system's output into an `AtpClient.Result`.

  Three readings run in order, and the first that finds something decides:

    1. The SZS status line, through `Tptp.Szs.status/1`: the last status line in the
       output, with its value looked up in `Tptp.Szs.Ontology`. A word the ontology
       does not define is reported as `{:error, {:unknown_szs_status, word}}`, not
       converted to an atom. A value from the data ontology on a status line, such
       as `Proof`, is `{:error, {:not_a_status, value}}`.
    2. The SystemOnTPTP summary line, `<system> says <Value>`, which SystemOnTPTP
       prints for every system it ran and which carries the same vocabulary.
    3. Prover-specific messages from systems that do not (always) print an SZS
       line — Alt-Ergo, E, LEO-II, SPASS, Vampire, Waldmeister. The table is
       `patterns/0`. Each entry maps to the most faithful SZS value the message
       alone supports; where a verdict is sound only under flags the reader cannot
       see, such as SPASS saturating under `-SOS`, the entry is the conservative
       `:gave_up`.

  Output none of the three reads is `{:error, {:unrecognized_output, output}}`.

  Isabelle does not print SZS lines; `AtpClient.Isabelle.Verdict` reads its
  messages.
  """

  alias AtpClient.Result
  alias Tptp.Szs
  alias Tptp.Szs.Ontology

  @typedoc """
  Why no result could be read from the output.

    * `{:unknown_szs_status, word}` — a status line names a value the ontology does
      not define.
    * `{:not_a_status, value}` — a status line names a data value.
    * `{:unrecognized_output, output}` — no status line and no known pattern.
    * `:internal_error` — a pattern that identifies a crash of the system rather
      than a verdict.
  """
  @type failure ::
          {:unknown_szs_status, binary()}
          | {:not_a_status, Ontology.t()}
          | {:unrecognized_output, binary()}
          | :internal_error

  @patterns [
    # Alt-Ergo (Why3-wrapped: ": Valid", ": Timeout"; native: "I don't know")
    {": Valid", {:ok, :theorem}},
    {": Timeout", {:ok, :timeout}},
    {": Unknown", {:ok, :unknown}},
    {"I don't know", {:ok, :gave_up}},

    # E
    {"Failure: Resource limit exceeded (time)", {:ok, :timeout}},
    {"Failure: Resource limit exceeded (memory)", {:ok, :memory_out}},
    {"time limit exceeded", {:ok, :timeout}},

    # LEO-II
    {"CPU time limit exceeded, terminating", {:ok, :timeout}},
    {"No.of.Axioms", {:ok, :gave_up}},

    # SPASS. "Completion found" is a saturation, which witnesses
    # (counter)satisfiability only under a refutationally complete strategy the
    # reader cannot verify. Input rejections are the system's own InputError
    # verdict; "Please report this error" is a crash.
    {"SPASS beiseite: Completion found", {:ok, :gave_up}},
    {"SPASS beiseite: Ran out of time", {:ok, :timeout}},
    {"SPASS beiseite: Maximal number of loops exceeded", {:ok, :resource_out}},
    {"No formulae and clauses found in input file", {:ok, :input_error}},
    {"Undefined symbol", {:ok, :input_error}},
    {"Free Variable", {:ok, :input_error}},
    {"Please report this error", {:error, :internal_error}},

    # Vampire. Saturation without SZS mode does not say whether a conjecture was
    # present, so it is :gave_up; in SZS mode Vampire prints the line itself.
    {"UNPROVABLE", {:ok, :gave_up}},
    {"CANNOT PROVE", {:ok, :gave_up}},
    {"Satisfiability detected", {:ok, :gave_up}},
    {"Termination reason: Satisfiable", {:ok, :gave_up}},
    {"Time limit reached!", {:ok, :timeout}},
    {"Aborted by signal SIGINT", {:ok, :forced}},

    # Waldmeister. "Unexpected end of file" is what non-UEQ input produces.
    {"Too many function symbols", {:ok, :resource_out}},
    {"****  Unexpected end of file.", {:ok, :inappropriate}},
    {"Unrecoverable Segmentation Fault", {:error, :internal_error}}
  ]

  @says ~r/\bsays\s+([A-Z][A-Za-z]{2,39})\b/

  @doc """
  Reads `output` from `backend` into a result.

  `fields` are put on the result as given: `:system` names the system that ran.

      iex> {:ok, result} = AtpClient.Verdict.interpret("# SZS status Theorem\\n", AtpClient.LocalExec, system: "eprover")
      iex> {result.status, result.evidence, result.system}
      {:theorem, :szs, "eprover"}

      iex> AtpClient.Verdict.interpret("% SZS status Nonsense for x", AtpClient.LocalExec)
      {:error, {:unknown_szs_status, "Nonsense"}}

      iex> {:ok, result} = AtpClient.Verdict.interpret("SPASS beiseite: Completion found", AtpClient.LocalExec)
      iex> {result.status, result.evidence}
      {:gave_up, {:pattern, "SPASS beiseite: Completion found"}}

      iex> AtpClient.Verdict.interpret("nothing to see", AtpClient.LocalExec)
      {:error, {:unrecognized_output, "nothing to see"}}
  """
  @spec interpret(binary(), module(), keyword()) :: {:ok, Result.t()} | {:error, failure()}
  def interpret(output, backend, fields \\ []) when is_binary(output) and is_atom(backend) do
    with :none <- szs(output, backend, fields),
         :none <- says(output, backend, fields),
         :none <- pattern(output, backend, fields) do
      {:error, {:unrecognized_output, output}}
    end
  end

  @doc """
  The prover-specific messages read when no SZS line is present, each with the
  result it stands for.
  """
  @spec patterns() :: [{binary(), {:ok, Ontology.t()} | {:error, :internal_error}}]
  def patterns, do: @patterns

  @spec szs(binary(), module(), keyword()) :: {:ok, Result.t()} | {:error, failure()} | :none
  defp szs(output, backend, fields) do
    case Szs.status(output) do
      {:ok, value, problem, comment} ->
        status(value, :szs, output, backend, [problem: problem, comment: comment] ++ fields)

      {:error, word, _problem, _comment} ->
        {:error, {:unknown_szs_status, word}}

      :none ->
        :none
    end
  end

  @spec says(binary(), module(), keyword()) :: {:ok, Result.t()} | {:error, failure()} | :none
  defp says(output, backend, fields) do
    case Regex.run(@says, output) do
      [matched, word] ->
        case Ontology.from_string(word) do
          {:ok, value} -> status(value, {:pattern, matched}, output, backend, fields)
          :error -> {:error, {:unknown_szs_status, word}}
        end

      nil ->
        :none
    end
  end

  @spec pattern(binary(), module(), keyword()) ::
          {:ok, Result.t()} | {:error, failure()} | :none
  defp pattern(output, backend, fields) do
    case Enum.find(@patterns, fn {text, _verdict} -> String.contains?(output, text) end) do
      {text, {:ok, value}} -> result(value, {:pattern, text}, output, backend, fields)
      {_text, {:error, _reason} = error} -> error
      nil -> :none
    end
  end

  @spec status(Ontology.t(), Result.evidence(), binary(), module(), keyword()) ::
          {:ok, Result.t()} | {:error, failure()}
  defp status(value, evidence, output, backend, fields) do
    if Ontology.success?(value) or Ontology.no_success?(value) do
      result(value, evidence, output, backend, fields)
    else
      {:error, {:not_a_status, value}}
    end
  end

  @spec result(Ontology.t(), Result.evidence(), binary(), module(), keyword()) ::
          {:ok, Result.t()}
  defp result(value, evidence, output, backend, fields) do
    base = %Result{
      status: value,
      evidence: evidence,
      output: output,
      backend: backend,
      blocks: Szs.blocks(output)
    }

    {:ok, struct!(base, fields)}
  end
end
