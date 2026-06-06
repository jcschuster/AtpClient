defmodule AtpClient.Isabelle.Session do
  @moduledoc """
  Handle for an open Isabelle server session.

  Wraps an `%IsabelleClient{}` from the `:isabelle_elixir` package — which
  owns the underlying TCP socket and a stack of active server sessions —
  together with the resolved configuration the session was opened with, so
  follow-up calls can pick up the same `local_dir` / `isabelle_dir` without
  being passed them again.
  """

  @enforce_keys [:client, :config]
  defstruct [:client, :config]

  @type t :: %__MODULE__{
          client: IsabelleClient.t(),
          config: keyword()
        }
end
