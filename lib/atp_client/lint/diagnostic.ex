defmodule AtpClient.Lint.Diagnostic do
  @moduledoc """
  One structured issue produced by an `AtpClient.Lint` backend.

  Positions are 1-based and character-oriented to match Monaco Editor's
  marker API directly; this keeps the Smart Cell JS layer free of any
  index translation. `end_line` / `end_column` are optional — when
  omitted, consumers typically highlight a single character starting at
  `{line, column}`.

  The `:source` field identifies which backend produced the diagnostic
  (`"local"` or `"tptp4x"`) and is shown in Monaco's problem hover, so
  users can tell at a glance whether an issue is a cheap structural
  check or an authoritative TPTP4x verdict.
  """

  @enforce_keys [:line, :column, :severity, :message]
  defstruct [:line, :column, :end_line, :end_column, :severity, :message, :source]

  @type severity :: :error | :warning | :info | :hint

  @type t :: %__MODULE__{
          line: pos_integer(),
          column: pos_integer(),
          end_line: pos_integer() | nil,
          end_column: pos_integer() | nil,
          severity: severity(),
          message: String.t(),
          source: String.t() | nil
        }
end
