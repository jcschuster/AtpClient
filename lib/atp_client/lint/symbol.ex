defmodule AtpClient.Lint.Symbol do
  @moduledoc """
  A symbol extracted from a TPTP source, currently always a declared
  type coming from a `type`-role statement.

  Powers the Monaco hover provider (hovering over `plus` in a formula
  shows `plus : nat > (nat > nat)`) and completion provider (declared
  symbols are offered alongside keywords) in the Smart Cell.

  `type` is the right-hand side of the declaration, reconstructed from
  the token stream — so whitespace is normalized but the logical
  content matches the source.
  """

  @enforce_keys [:name, :kind, :line, :column]
  defstruct [:name, :kind, :type, :line, :column]

  @type kind :: :type_decl

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          type: String.t() | nil,
          line: pos_integer(),
          column: pos_integer()
        }
end
