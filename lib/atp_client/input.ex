defprotocol AtpClient.Input do
  @moduledoc """
  What a backend accepts as its input: the problem to prove, or the solution to
  verify.

  Every `query/2` takes one of these and asks it for the bytes a prover will read.
  Parsing is never a side effect of proving: a binary is transmitted as it is, a
  `Tptp.File` as the source it was read from, and a `Tptp.Unit` as its statements
  sliced from their files. The library copies none of the problem text; a slice
  is a sub-binary of the file it came from, except that the runtime materialises
  slices of up to 64 bytes as small binaries of their own.

  | Input | `to_iodata/1` |
  |-------|---------------|
  | `binary()` | the binary itself |
  | `iodata()` | as given — a tree printed with `Tptp.Printer.Canonical.to_iodata/1` |
  | `Tptp.File` | `file.source` |
  | `Tptp.Unit` | every statement in textual-inclusion order, each a sub-binary of the file it came from |
  | `Tptp.Derivation` | `derivation.file.source` |
  | `AtpClient.Interpretation` | `AtpClient.Interpretation.to_tptp/1` |

  A `Tptp.File` is the text it was read from. A tree that has been modified is sent
  by printing it:

      problem = Tptp.Printer.Canonical.to_iodata(file)
      AtpClient.LocalExec.query(problem, binary: "eprover")

  A `Tptp.Unit` is what textual inclusion denotes: the root's statements with each
  `include` replaced by the statements it reaches, selections applied. Comments
  are not part of a statement and are left out, and a directive the unit did not
  resolve contributes nothing — `unit.diagnostics` recorded that at read time. A
  prover that resolves includes itself, such as SystemOnTPTP against its own axiom
  library, is handed the root file instead.

  A `Tptp.Derivation` and an `AtpClient.Interpretation` are what
  `AtpClient.SystemOnTptp.process_solution/3` and `AtpClient.verify/2` hand a
  verifier.

  Implementing this protocol is how another library hands its own problem
  representation to a backend without this library depending on it. This
  protocol was `AtpClient.Problem` before 0.8.
  """

  @doc """
  The bytes the prover reads.
  """
  @spec to_iodata(t) :: iodata()
  def to_iodata(input)

  @doc """
  A name for the problem, where it has one: the base name of the file it was read
  from. Used where a backend has to name what it submits.
  """
  @spec name(t) :: binary() | nil
  def name(input)
end

defimpl AtpClient.Input, for: BitString do
  def to_iodata(binary), do: binary
  def name(_binary), do: nil
end

defimpl AtpClient.Input, for: List do
  def to_iodata(iodata), do: iodata
  def name(_iodata), do: nil
end

defimpl AtpClient.Input, for: Tptp.File do
  def to_iodata(%Tptp.File{source: source}), do: source

  def name(%Tptp.File{path: nil}), do: nil
  def name(%Tptp.File{path: path}), do: Path.basename(path)
end

defimpl AtpClient.Input, for: Tptp.Unit do
  def to_iodata(%Tptp.Unit{} = unit) do
    unit
    |> Tptp.Unit.statements()
    |> Enum.map(fn {id, statement} ->
      [Tptp.Statement.text(statement, unit.files[id].source), ?\n]
    end)
  end

  def name(%Tptp.Unit{} = unit), do: AtpClient.Input.name(unit.files[unit.root])
end

defimpl AtpClient.Input, for: Tptp.Derivation do
  def to_iodata(%Tptp.Derivation{file: file}), do: AtpClient.Input.to_iodata(file)
  def name(%Tptp.Derivation{file: file}), do: AtpClient.Input.name(file)
end
