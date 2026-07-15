defmodule AtpClient.Isabelle.Session do
  @moduledoc """
  Opaque handle for an open Isabelle server session.

  Wraps a `IsabelleClient.Shared` GenServer PID — which owns the underlying
  TCP socket, the active Isabelle session, and routes async task messages so
  multiple concurrent callers can share it safely — together with the resolved
  configuration the session was opened with, so follow-up calls can pick up
  the same `local_dir` / `isabelle_dir` without being passed them again.

  Construct only via `AtpClient.Isabelle.open_session/1`; tear down via
  `AtpClient.Isabelle.close_session/1`. The struct's field names and
  shapes are not part of the public contract — access via `.` from
  outside this module is a dialyzer opacity violation, use
  `client/1`, `owner/1`, `config/1` instead.
  """

  @enforce_keys [:client, :owner, :config]
  defstruct [:client, :owner, :config]

  @opaque t :: %__MODULE__{
            client: pid(),
            owner: pid(),
            config: keyword()
          }

  @doc """
  Constructs a `Session` from its component pids and the resolved config.
  Internal — called only from `AtpClient.Isabelle.open_session/1`.
  """
  @spec new(pid(), pid(), keyword()) :: t()
  def new(client, owner, config)
      when is_pid(client) and is_pid(owner) and is_list(config) do
    %__MODULE__{client: client, owner: owner, config: config}
  end

  @doc """
  Returns the underlying `IsabelleClient.Shared` GenServer pid — the one
  that owns the TCP socket and routes async task messages.
  """
  @spec client(t()) :: pid()
  def client(%__MODULE__{client: pid}), do: pid

  @doc """
  Returns the `AtpClient.Isabelle.SessionOwner` pid that isolates the
  Shared process's link from the caller.
  """
  @spec owner(t()) :: pid()
  def owner(%__MODULE__{owner: pid}), do: pid

  @doc """
  Returns the resolved config the session was opened with — used by
  follow-up `prove_*` calls so the caller doesn't have to re-supply
  `:local_dir`, `:isabelle_dir`, and friends on every request.
  """
  @spec config(t()) :: keyword()
  def config(%__MODULE__{config: cfg}), do: cfg
end
