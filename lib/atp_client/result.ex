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

  ## Output

  `output` is the system's output as the backend received it, so nothing it printed
  is lost. `blocks` are the `% SZS output start … end` sections in it, and
  `proof/1` reads the first proof block as TPTP.
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
  @type evidence :: :szs | {:pattern, binary()} | {:backend, module()}

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
    * `details` — backend-specific detail, such as per-lemma results from Isabelle.
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
  The first output block whose dataform is within the SZS `Proof` dataform —
  `Proof`, `Refutation`, `CNFRefutation` or `Derivation` — read as TPTP.

  A derivation is a sequence of annotated formulae whose `source` records the
  inference that produced each one, so the result's statements carry the proof
  structure. The body is read as it appears in the output; a prefix a job runner
  put on every line, as StarExec does, is read along with it and reported in the
  diagnostics.

  Returns `:none` when the output holds no such block.
  """
  @spec proof(t()) :: {:ok, Tptp.File.t(), [Tptp.Diagnostic.t()]} | :none
  def proof(%__MODULE__{blocks: blocks}) do
    case Enum.find(blocks, &Ontology.isa?(&1.dataform, :proof)) do
      nil -> :none
      %{body: body} -> Tptp.from_string(body)
    end
  end
end
