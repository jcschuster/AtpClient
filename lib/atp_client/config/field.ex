defmodule AtpClient.Config.Field do
  @moduledoc """
  One configurable setting on a backend, in a shape a UI can render directly.

  Backends declare their schema via `c:AtpClient.Backend.config_schema/0`. The
  Smart Cell (or any other UI) iterates the returned list to render a form,
  using `:group` to lay out sections and `:secret?` to decide masking.
  """

  @enforce_keys [:key, :type, :required?, :group]
  defstruct [:key, :type, :required?, :group, :default, :label, :doc, secret?: false]

  @typedoc """
  Logical type of the value. The UI maps these to input widgets; the library
  itself does no coercion — values flow into `Application.put_env/3` and the
  per-call opts as-is.
  """
  @type type :: :string | :integer | :boolean | :string_list

  @typedoc """
  Layout hint for the UI:

    * `:connection` — needed to reach the backend at all (auth, endpoints).
      `verify/1` validates these.
    * `:defaults` — used by high-level helpers (`prove/3`, `query/2`, …) but
      not required to talk to the backend.
    * `:advanced` — endpoint paths and other knobs most users never touch.
  """
  @type group :: :connection | :defaults | :advanced

  @type t :: %__MODULE__{
          key: atom(),
          type: type(),
          required?: boolean(),
          group: group(),
          default: any(),
          label: String.t() | nil,
          doc: String.t() | nil,
          secret?: boolean()
        }
end
