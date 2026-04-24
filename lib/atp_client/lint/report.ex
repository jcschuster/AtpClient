defmodule AtpClient.Lint.Report do
  @moduledoc """
  The combined output of a lint pass: a list of `Diagnostic`s and a list
  of `Symbol`s.

  Diagnostics are always present (possibly empty). Symbols are populated
  by backends that can introspect the source structurally; at the time
  of writing, only `AtpClient.Lint.Local` contributes symbols, so
  running `AtpClient.Lint` with `backends: [:tptp4x]` produces an empty
  symbol list.
  """

  @enforce_keys [:diagnostics, :symbols]
  defstruct [:diagnostics, :symbols]

  @type t :: %__MODULE__{
          diagnostics: [AtpClient.Lint.Diagnostic.t()],
          symbols: [AtpClient.Lint.Symbol.t()]
        }
end
