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

  ## Two error channels

  `query/2` returns either an `t:AtpClient.ResultNormalization.atp_result/0`
  or an outer `{:error, term()}`. They mean different things and callers
  usually want to route them differently:

    * `{:ok, szs_status}` and `{:error, failure}` (from `atp_result()`) are
      the **classifier's** verdict: the prover ran and returned an SZS
      status the classifier could interpret, or produced output the
      classifier could not parse. Failure atoms are enumerated in
      `t:AtpClient.ResultNormalization.failure_t/0` (`:internal_error`,
      `:input_error`, `{:prover_not_found, name}`,
      `{:unrecognized_output, raw}`).
    * `{:error, term()}` outside `failure_t()` is a **transport /
      session** error: connection refused, HTTP status, session-open
      failure, missing config, Isabelle "cannot load theory file", etc.
      The shape is backend-specific and not exhaustively enumerated —
      match `{:error, _}` as a catch-all after the classified branches.

  A common Idiom:

      case Backend.query(problem, opts) do
        {:ok, status}                 -> :prover_verdict
        {:error, {:prover_not_found, _}} -> :missing_binary
        {:error, {:unrecognized_output, _}} -> :bad_parse
        {:error, reason}              -> {:transport, reason}
      end

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
