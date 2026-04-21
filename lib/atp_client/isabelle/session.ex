defmodule AtpClient.Isabelle.Session do
  @moduledoc """
  Handle for an open Isabelle server session.

  Holds the underlying socket (a `Port` returned by
  `IsabelleClientMini.connect/3`), the server-assigned `session_id`, and the
  resolved configuration the session was opened with — so follow-up calls can
  pick up the same `local_dir` / `isabelle_dir` without being passed them again.
  """

  @enforce_keys [:socket, :session_id, :config]
  defstruct [:socket, :session_id, :config]

  @type t :: %__MODULE__{
          socket: port(),
          session_id: String.t(),
          config: keyword()
        }
end
