defmodule AtpClient.Backend do
  @moduledoc """
  Behaviour every backend implements so a UI (Smart Cell, Livebook, …) can
  discover its configurable settings and probe reachability without
  hard-coding per-backend knowledge.

  ## Smart Cell sketch

      for module <- AtpClient.backends() do
        %{
          key:    module.config_key(),
          label:  module.label(),
          fields: module.config_schema()
        }
      end

      # Once the user fills the form:
      AtpClient.StarExec.verify(
        base_url: "https://...",
        username: "...",
        password: "..."
      )
      # => :ok | {:error, term}

  `verify/1` accepts the same keyword list every other backend call accepts,
  so the cell can probe without first writing values into `Application` env.

  ## Cancellation contract

  Each backend treats the death of the process calling `query/2` as a
  request to abort. Implementations must (a) release external resources —
  OS children, network connections, remote jobs — and (b) clean up state
  held in helper processes. Death-as-cancellation is the only required
  cancellation mechanism; backends may additionally expose explicit
  handles, but they are not required to.

  The intended use is `Process.exit(task_pid, :kill)` from a supervisor
  task running `query/2`: the host kills the Task, the backend tears the
  upstream work down, and no resource is left running.
  """

  alias AtpClient.Config.Field

  @doc "Stable atom used in `Application.get_env(:atp_client, key)`."
  @callback config_key() :: AtpClient.Config.backend()

  @doc "Human-friendly backend name."
  @callback label() :: String.t()

  @doc """
  Returns the schema of configurable settings. The order is the order a UI
  should render fields in; group with `Field`'s `:group` to lay out sections.
  """
  @callback config_schema() :: [Field.t()]

  @doc """
  Checks that `opts` are sufficient to reach the backend. Returns `:ok` on
  success or `{:error, reason}` with a reason specific enough that the UI
  can tell "wrong credentials" from "no route to host".
  """
  @callback verify(keyword()) :: :ok | {:error, term()}

  @doc """
  Runs `problem` (a TPTP-format string) against the backend with the given
  `opts` and collapses everything to a single
  `t:AtpClient.ResultNormalization.atp_result/0`.

  Each backend hides its own ceremony (session login/logout, prover
  selection, theory-file bookkeeping) behind this call so a UI can dispatch
  on backend module alone.
  """
  @callback query(String.t(), keyword()) ::
              AtpClient.ResultNormalization.atp_result() | {:error, term()}
end
