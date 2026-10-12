defmodule AtpClient.SystemOnTptp.Provers do
  @moduledoc """
  Stateful `Agent` that caches the system identifiers currently advertised by
  a SystemOnTPTP deployment.

  The initial refresh is triggered in the background once the agent starts.
  `get_systems_list/0` and `systems/0` block on the first call until the
  initial refresh completes or `refresh_timeout_ms` elapses. Subsequent calls
  return the cached list immediately. Callers can force a re-fetch via
  `refresh_systems_list/0`.

  ## Names and identifiers

  SystemOnTPTP identifies a system as `<name>---<version>`, `Vampire---5.0.1`,
  and keeps only the current version of each. `resolve/1` accepts either form:
  an identifier is checked against the advertised list, and a bare name is
  resolved to the latest version advertised under it, so a caller writes
  `"Vampire"` and is not tied to a version string that changes under them.

  The agent is started with the application under
  `config :atp_client, :sotptp, auto_refresh: true` (the default). Without it,
  nothing is cached and `resolve/1` passes identifiers through unchanged, since
  it has nothing to check them against.
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
        Logger.warning("#{inspect(__MODULE__)}: initial refresh failed: #{inspect(reason)}")

        Agent.update(__MODULE__, fn
          nil -> %{systems: [], provers: []}
          existing -> existing
        end)
    end
  end

  @doc """
  Returns the list of available provers (e.g. `"cvc5---1.3.0"`): every
  advertised system except the format converters, checkers and statistics
  tools SystemOnTPTP lists alongside them.

  Blocks on the first call until the background refresh triggered at startup
  completes or `refresh_timeout_ms` elapses; subsequent calls return the
  cached list immediately.
  """
  @spec get_systems_list() :: [String.t()]
  def get_systems_list, do: loaded().provers

  @doc """
  Every system the deployment advertises, tools included.

  Blocks like `get_systems_list/0`. Returns `[]` when the agent is not running.
  """
  @spec systems() :: [String.t()]
  def systems do
    if Process.whereis(__MODULE__), do: loaded().systems, else: []
  end

  @doc """
  The name of a system identifier: `"Vampire"` for `"Vampire---5.0.1"`. A bare
  name is returned as it is.

      iex> AtpClient.SystemOnTptp.Provers.name("Vampire---5.0.1")
      "Vampire"
  """
  @spec name(String.t()) :: String.t()
  def name(system) when is_binary(system) do
    system |> String.split("---", parts: 2) |> hd()
  end

  @doc """
  Resolves a system name or identifier against the advertised systems.

  An identifier (`"E---3.5.1"`) must be advertised as written. A bare name
  (`"E"`) resolves to the latest version advertised under it, versions being
  compared component-wise as numbers. When no list is available — the agent is
  not running, or the deployment could not be reached — an identifier is passed
  through unchanged and a bare name cannot be resolved.

      iex> systems = ["E---3.5.1", "Vampire---5.0.1", "Vampire---4.8", "TPTP4X---0.0"]
      iex> AtpClient.SystemOnTptp.Provers.resolve("Vampire", systems)
      {:ok, "Vampire---5.0.1"}
      iex> AtpClient.SystemOnTptp.Provers.resolve("Vampire---4.8", systems)
      {:ok, "Vampire---4.8"}
      iex> AtpClient.SystemOnTptp.Provers.resolve("Vampire---4.7", systems)
      {:error, {:unknown_system, "Vampire---4.7"}}
      iex> AtpClient.SystemOnTptp.Provers.resolve("Nope", systems)
      {:error, {:unknown_system, "Nope"}}
      iex> AtpClient.SystemOnTptp.Provers.resolve("Nope---1", [])
      {:ok, "Nope---1"}
  """
  @spec resolve(String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, {:unknown_system, String.t()}}
  def resolve(system, systems \\ systems()) when is_binary(system) and is_list(systems) do
    cond do
      system in systems -> {:ok, system}
      systems == [] and String.contains?(system, "---") -> {:ok, system}
      String.contains?(system, "---") -> {:error, {:unknown_system, system}}
      true -> latest(system, systems)
    end
  end

  @spec latest(String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, {:unknown_system, String.t()}}
  defp latest(name, systems) do
    case Enum.filter(systems, &(name(&1) == name)) do
      [] -> {:error, {:unknown_system, name}}
      versions -> {:ok, Enum.max_by(versions, &version_key/1)}
    end
  end

  # "5.0.1" sorts after "4.8" and "2.1.9999" after "2.1.10": each component is
  # compared as a number where it is one, and as text otherwise.
  @spec version_key(String.t()) :: [tuple()]
  defp version_key(system) do
    case String.split(system, "---", parts: 2) do
      [_name, version] -> version |> String.split(".") |> Enum.map(&component/1)
      [_name] -> []
    end
  end

  defp component(text) do
    case Integer.parse(text) do
      {number, rest} -> {1, number, rest}
      :error -> {0, 0, text}
    end
  end

  @spec loaded() :: %{systems: [String.t()], provers: [String.t()]}
  defp loaded do
    case Agent.get(__MODULE__, & &1) do
      nil ->
        timeout = Config.fetch(:sotptp, :refresh_timeout_ms, 15_000)
        wait_until_loaded(System.monotonic_time(:millisecond) + timeout)

      state ->
        state
    end
  end

  @spec wait_until_loaded(integer()) :: %{systems: [String.t()], provers: [String.t()]}
  defp wait_until_loaded(deadline) do
    case Agent.get(__MODULE__, & &1) do
      nil ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(50, remaining))
          wait_until_loaded(deadline)
        else
          %{systems: [], provers: []}
        end

      state ->
        state
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
           finch: [name: AtpClient.TptpFinch],
           compressed: false,
           receive_timeout: timeout_ms,
           retry: :transient,
           retry_delay: fn _ -> 500 end
         ) do
      {:ok, %{status: 200, body: body}} ->
        systems =
          body
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.contains?(&1, "---"))
          |> Enum.uniq()
          |> Enum.sort_by(&String.upcase/1)

        provers =
          Enum.reject(systems, fn system ->
            Enum.any?(@excluded_systems, &String.starts_with?(system, &1 <> "---"))
          end)

        Agent.update(__MODULE__, fn _ -> %{systems: systems, provers: provers} end)

      {:ok, %{status: status}} ->
        {:error, "API Error: status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
