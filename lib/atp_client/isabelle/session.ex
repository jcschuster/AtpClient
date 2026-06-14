defmodule AtpClient.Isabelle.Session do
  @moduledoc """
  Handle for an open Isabelle server session.

  Wraps a `IsabelleClient.Shared` GenServer PID — which owns the underlying
  TCP socket, the active Isabelle session, and routes async task messages so
  multiple concurrent callers can share it safely — together with the resolved
  configuration the session was opened with, so follow-up calls can pick up
  the same `local_dir` / `isabelle_dir` without being passed them again.
  """

  @enforce_keys [:client, :config]
  defstruct [:client, :config]

  @type t :: %__MODULE__{
          client: pid(),
          config: keyword()
        }
end
