defmodule AtpClient.Result do
  @moduledoc """
  What a backend returns when the system it ran asserted a result.

  `status` is the system's SZS verdict as a value of `Tptp.Szs.Ontology`: `:theorem`,
  `:counter_satisfiable`, `:timeout`, `:gave_up`, and the rest of the success and
  no-success ontologies. A value is never created from prover output; a status word
  outside the ontology is an `{:error, {:unknown_szs_status, word}}` from the backend
  rather than a result.

  ## The two channels

  `{:ok, %AtpClient.Result{}}` means the system ran and asserted a status, including
  the no-success ones: `Timeout`, `GaveUp` and `InputError` are results. `{:error,
  reason}` means no status could be obtained: a transport or session failure, a
  missing binary, output that carries no status line and matches no known pattern,
  or a status word the ontology does not define. Match the classified reasons a
  backend documents first and `{:error, _}` last.

  ## Evidence

  `evidence` records how the status was obtained, so a caller can decide how much
  to trust it:

    * `:szs` — from an SZS status line in the output, read by `Tptp.Szs.status/1`.
    * `{:pattern, text}` — from a prover-specific message a system prints instead
      of an SZS line; `AtpClient.Verdict` keeps the table. `text` is the matched
      pattern.
    * `{:backend, module}` — from a backend's own classifier over structured
      output, which is how `AtpClient.Isabelle` reads Isabelle's messages.
    * `{:tstp, "Result"}` — from the `Result` header of a TSTP solution file whose
      archived system output holds no status SystemOnTPTP's reply shape can be
      read by; see `AtpClient.SystemOnTptp.read_section/2`.
    * `{:system_info, key}` — from one of the system's own `Solved` patterns in
      its SystemOnTPTP record, `key` the word the record maps it from
      (`"VerifiedGood"`); see `AtpClient.Verdict`.

  ## Output

  `output` is the system's output as the backend received it, so nothing it printed
  is lost. `blocks` are the `% SZS output start … end` sections in it, read by
  `Tptp.Szs.blocks/2` — with StarExec's elapsed-time prefix removed from every
  body line for a StarExec result, and from the archived system output
  (`details.tstp.original`) for a SystemOnTPTP reply in the TSTP shape.
  `details.tstp` is that `Tptp.Tstp.Solution`, `nil` or absent elsewhere.

  ## Readings

  A result is the system's assertion and what it printed. What the output
  *says* — a derivation, a model, a list of formulae — is read on demand by the
  functions here, never while the backend runs:

    * `derivation/1` — a proof as a `Tptp.Derivation`;
    * `interpretation/1` — a model as an `AtpClient.Interpretation`;
    * `formulae/1` — the formulae a transformation tool returned;
    * `proof/1` — the thin reading under `derivation/1`, a proof block as a
      `Tptp.File`.
  """

  alias Tptp.Szs.Ontology

  @enforce_keys [:status, :evidence, :output, :backend]
  defstruct [
    :status,
    :evidence,
    :output,
    :backend,
    :system,
    :problem,
    :comment,
    blocks: [],
    details: %{}
  ]

  @typedoc "How a status was obtained."
  @type evidence ::
          :szs
          | {:pattern, binary()}
          | {:backend, module()}
          | {:tstp, binary()}
          | {:system_info, binary()}

  @typedoc """
  A system's asserted result.

    * `status` — the SZS value.
    * `evidence` — see `t:evidence/0`.
    * `output` — the system's output, verbatim.
    * `backend` — the backend module that produced this result.
    * `system` — the system's identifier where the backend has one, such as a
      SystemOnTPTP system id or a local binary.
    * `problem` — the problem named on the status line, where the line names one.
    * `comment` — free text after the `:` on the status line, where present.
    * `blocks` — delimited SZS output blocks, in order.
    * `details` — backend-specific detail: the `Tptp.Tstp.Solution` under `:tstp`
      for SystemOnTPTP in the TSTP shape, per-lemma results and the Nitpick
      message (`:nitpick`) from Isabelle.
  """
  @type t :: %__MODULE__{
          status: Ontology.t(),
          evidence: evidence(),
          output: binary(),
          backend: module(),
          system: binary() | nil,
          problem: binary() | nil,
          comment: binary() | nil,
          blocks: [Tptp.Szs.block()],
          details: map()
        }

  @doc """
  Whether the status is in the SZS success ontology.

      iex> {:ok, result} = AtpClient.Verdict.interpret("% SZS status Theorem for x", AtpClient.LocalExec)
      iex> AtpClient.Result.success?(result)
      true
      iex> {:ok, result} = AtpClient.Verdict.interpret("% SZS status Timeout for x", AtpClient.LocalExec)
      iex> AtpClient.Result.success?(result)
      false
  """
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{status: status}), do: Ontology.success?(status)

  @doc """
  The derivation the system printed, read as a `Tptp.Derivation`.

  The source is, in order: the solution region of a TSTP reply,
  `details.tstp.solution`, when it holds statements; else the first block whose
  dataform is within `Proof` — `Proof`, `Refutation`, `CNFRefutation`,
  `Derivation`.

  `{:error, {:invalid_derivation, diagnostics}}` when the diagnostics hold an error
  (`Tptp.Diagnostic.any_errors?/1`). What `Tptp.Derivation` itself finds — a
  duplicate name, a parent that is not there, a cycle — is not an error and comes
  back with the `{:ok, …}`. `:none` when there is no derivation to read.
  """
  @spec derivation(t()) ::
          {:ok, Tptp.Derivation.t(), [Tptp.Diagnostic.t()]}
          | {:error, {:invalid_derivation, [Tptp.Diagnostic.t()]}}
          | :none
  def derivation(%__MODULE__{} = result) do
    case solution_file(result, :proof) || proof_file(result) do
      nil ->
        :none

      %Tptp.File{} = file ->
        {:ok, derivation, found} = Tptp.Derivation.from_file(file)
        diagnostics = Enum.uniq(file.diagnostics ++ found)

        if Tptp.Diagnostic.any_errors?(diagnostics),
          do: {:error, {:invalid_derivation, diagnostics}},
          else: {:ok, derivation, diagnostics}
    end
  end

  @doc """
  The interpretation the system printed — a finite model, a Herbrand model, a
  saturation — read as an `AtpClient.Interpretation`.

  The source is the solution region of a TSTP reply whose `Output` is an
  interpretation, else the first block whose dataform is within
  `Interpretation` — `FiniteModel`, `Model`, `Saturation` among them, a
  saturation being a `FormulaHerbrandModel` in the ontology. It is read by
  `AtpClient.Interpretation.from_file/2`. For an Isabelle result
  (`evidence: {:backend, AtpClient.Isabelle}`) it is the Nitpick message in
  `details.nitpick`, read by `AtpClient.Isabelle.Nitpick`.

  `{:error, {:invalid_interpretation, reason}}` when the text does not parse, or
  none of the readers recognises it (`reason` the diagnostics, or
  `:unrecognised`). `:none` when there is no interpretation to read.
  """
  @spec interpretation(t()) ::
          {:ok, AtpClient.Interpretation.t(), [Tptp.Diagnostic.t()]}
          | {:error, {:invalid_interpretation, term()}}
          | :none
  def interpretation(%__MODULE__{evidence: {:backend, AtpClient.Isabelle}} = result) do
    case result.details do
      %{nitpick: message} when is_binary(message) -> AtpClient.Isabelle.Nitpick.read(message)
      _otherwise -> :none
    end
  end

  def interpretation(%__MODULE__{} = result) do
    case interpretation_source(result) do
      nil ->
        :none

      {{:ok, file, diagnostics}, dataform} ->
        if Tptp.Diagnostic.any_errors?(diagnostics),
          do: {:error, {:invalid_interpretation, diagnostics}},
          else: read_interpretation(file, diagnostics, dataform)
    end
  end

  defp interpretation_source(result) do
    case solution_file(result, :interpretation) do
      nil ->
        case Enum.find(result.blocks, &Ontology.isa?(&1.dataform, :interpretation)) do
          nil -> nil
          block -> {Tptp.from_string(block.body), block.dataform}
        end

      file ->
        {{:ok, file, file.diagnostics}, result.details.tstp.output}
    end
  end

  defp read_interpretation(file, diagnostics, dataform) do
    with {:ok, interpretation} <- AtpClient.Interpretation.from_file(file, dataform: dataform) do
      {:ok, interpretation, diagnostics}
    end
  end

  @doc """
  The formulae a transformation tool returned — ECNF's clauses, Monotonox-2FOF's
  or Prophet's formulae — read as a `Tptp.File`.

  The source is the first block whose dataform is within `ListOfFormulae`. The
  SystemOnTPTP tools name their blocks by the language they hold, `ListOfCNF`,
  `ListOfFOF`, `ListOfTFF`, and those names are not in the ontology; a block named
  `ListOf<anything>` is read as a `ListOfFormulae`. `:none` when there is no such
  block.
  """
  @list_of ~r/(SZS output (?:start|end)[ \t]+)ListOf[A-Za-z0-9]+/

  @spec formulae(t()) :: {:ok, Tptp.File.t(), [Tptp.Diagnostic.t()]} | :none
  def formulae(%__MODULE__{} = result) do
    result
    |> text()
    |> then(&Regex.replace(@list_of, &1, "\\1ListOfFormulae"))
    |> Tptp.Szs.blocks(prefix: prefix(result))
    |> Enum.find(&Ontology.isa?(&1.dataform, :list_of_formulae))
    |> case do
      nil -> :none
      %{body: body} -> read(body)
    end
  end

  @doc """
  The first output block whose dataform is within the SZS `Proof` dataform —
  `Proof`, `Refutation`, `CNFRefutation` or `Derivation` — read as TPTP.

  The thin reading under `derivation/1`: the statements, without the graph. A
  derivation is a sequence of annotated formulae whose `source` records the
  inference that produced each one, so the result's statements carry the proof
  structure. The body is read as `blocks` holds it, StarExec's prefix removed.

  Returns `:none` when the output holds no such block.
  """
  @spec proof(t()) :: {:ok, Tptp.File.t(), [Tptp.Diagnostic.t()]} | :none
  def proof(%__MODULE__{blocks: blocks}) do
    case Enum.find(blocks, &Ontology.isa?(&1.dataform, :proof)) do
      nil -> :none
      %{body: body} -> read(body)
    end
  end

  defp read(body), do: Tptp.from_string(body)

  # The solution region of a TSTP reply when the header's `Output` is within
  # `dataform` and the region holds statements.
  @spec solution_file(t(), Ontology.t()) :: Tptp.File.t() | nil
  defp solution_file(%__MODULE__{details: %{tstp: %Tptp.Tstp.Solution{} = solution}}, dataform) do
    with %Tptp.File{statements: [_ | _]} = file <- solution.solution,
         output when not is_nil(output) <- solution.output,
         true <- Ontology.isa?(output, dataform) do
      file
    else
      _otherwise -> nil
    end
  end

  defp solution_file(_result, _dataform), do: nil

  @spec proof_file(t()) :: Tptp.File.t() | nil
  defp proof_file(result) do
    case proof(result) do
      {:ok, file, _diagnostics} -> file
      :none -> nil
    end
  end

  # What the blocks were read from.
  defp text(%__MODULE__{details: %{tstp: %Tptp.Tstp.Solution{original: original}}})
       when is_binary(original),
       do: original

  defp text(%__MODULE__{output: output}), do: output

  defp prefix(%__MODULE__{backend: AtpClient.StarExec}), do: [Tptp.Szs.prefix(:starexec)]
  defp prefix(_result), do: []
end
