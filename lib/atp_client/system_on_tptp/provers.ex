defmodule AtpClient.SystemOnTptp.Provers do
  @moduledoc """
  Stateful `Agent` that caches the list of prover identifiers currently
  advertised by a SystemOnTPTP deployment.

  The initial refresh is triggered in the background once the agent starts.
  `get_systems_list/0` blocks on the first call until the initial refresh
  completes or `refresh_timeout_ms` elapses. Subsequent calls return the
  cached list immediately. Callers can force a re-fetch via
  `refresh_systems_list/0`.
  """
  use Agent

  require Logger

  alias AtpClient.Config

  # `refresh_systems_list/1` is called from `AtpClient.SystemOnTptp.verify/1`
  # with the full sotptp opts keyword — which is validated at that entry
  # point against `AtpClient.SystemOnTptp`'s schema. It would be wrong to
  # re-validate against a narrower schema here: `verify/1` legitimately
  # passes keys like `:default_time_limit_sec` through, and refusing them
  # at this hop would surface as a spurious `NimbleOptions.ValidationError`
  # from a valid `verify/1` call. Direct callers (no wrapping entry point)
  # take the pre-existing behaviour of silently ignoring unknown keys.

  # The "ListSystems" request returns all online systems, including format
  # converters, type-checking modes, statistics tools, and other non-prover
  # infrastructure. We exclude those by name prefix; everything else is
  # treated as a prover (including model finders, SAT solvers, etc.).
  @excluded_systems [
    "ACE2TPTP",
    "AGMV",
    "AGInTRater",
    "ATFLET",
    "BNFParser",
    "BNFParserTree",
    "CheckTyping",
    "CHewTPTP",
    "cvc5-STC",
    "Dedukti",
    "DFG2TPTP",
    "ECNF",
    "EGround",
    "GDV",
    "GDV-LP",
    "GetSymbols",
    "Horn2UEQ",
    "IDV",
    "IIV",
    "InterpretByATP",
    "Isabelle",
    "LADR2TPTP",
    "LambdaPi",
    "Leo-III-STC",
    "Monotonox",
    "Monotonox-2CNF",
    "Monotonox-2FOF",
    "Otter2TPTP",
    "PProofSummary",
    "ProblemStats",
    "ProofStats",
    "ProofSummary",
    "SC-TPTP",
    "SInE",
    "SInE-LTB",
    "SInE-XDB",
    "SMT2TPTP",
    "SolutionStats",
    "SPCForProblem",
    "TPII",
    "TPTP2JSON",
    "TPTP2X",
    "TPTP4X",
    "VCNF",
    "VSelect",
    "Why3-FOF",
    "Why3-TF0"
  ]

  @doc """
  Links the module as an `Agent` process with the caller process and
  schedules a background refresh of the system list.
  """
  @spec start_link(any()) :: {:ok, pid()} | {:error, any()}
  def start_link(_args) do
    with {:ok, pid} <- Agent.start_link(fn -> nil end, name: __MODULE__) do
      Task.start(&refresh_or_warn/0)
      {:ok, pid}
    end
  end

  defp refresh_or_warn do
    case refresh_systems_list() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "#{inspect(__MODULE__)}: initial refresh failed: #{inspect(reason)}"
        )

        Agent.update(__MODULE__, fn
          nil -> []
          existing -> existing
        end)
    end
  end

  @doc """
  Returns the list of available provers (e.g. `"cvc5---1.3.0"`).

  Blocks on the first call until the background refresh triggered at startup
  completes or `refresh_timeout_ms` elapses; subsequent calls return the
  cached list immediately.
  """
  @spec get_systems_list() :: [String.t()]
  def get_systems_list do
    case Agent.get(__MODULE__, & &1) do
      nil ->
        timeout = Config.fetch(:sotptp, :refresh_timeout_ms, 15_000)
        wait_until_loaded(System.monotonic_time(:millisecond) + timeout)

      list ->
        list
    end
  end

  defp wait_until_loaded(deadline) do
    case Agent.get(__MODULE__, & &1) do
      nil ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(50, remaining))
          wait_until_loaded(deadline)
        else
          []
        end

      list ->
        list
    end
  end

  @doc """
  Refreshes the cached system list via a synchronous query to SystemOnTPTP.

  Accepts the same options as the rest of the SoTPTP API:

    * `:url` — SystemOnTPTP endpoint (defaults to the configured URL);
    * `:refresh_timeout_ms` — request timeout in ms.
  """
  @spec refresh_systems_list(keyword()) :: :ok | {:error, any()}
  def refresh_systems_list(opts \\ []) do
    url = Config.fetch!(:sotptp, :url, opts)
    timeout_ms = Config.fetch(:sotptp, :refresh_timeout_ms, 15_000, opts)

    case Req.post(url,
           form: %{
             "SubmitButton" => "ListSystems",
             "ListStatus" => "READY",
             "QuietFlag" => "-q0",
             "NoHTML" => "1"
           },
           finch: AtpClient.TptpFinch,
           compressed: false,
           receive_timeout: timeout_ms,
           retry: :transient,
           retry_delay: fn _ -> 500 end
         ) do
      {:ok, %{status: 200, body: body}} ->
        systems_online =
          body
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.contains?(&1, "---"))
          |> Enum.uniq()
          |> Enum.reject(fn system ->
            Enum.any?(@excluded_systems, &String.starts_with?(system, &1 <> "---"))
          end)
          |> Enum.sort_by(&String.upcase/1)

        Agent.update(__MODULE__, fn _ -> systems_online end)

      {:ok, %{status: status}} ->
        {:error, "API Error: status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
