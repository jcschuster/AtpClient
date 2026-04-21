defmodule AtpClient.SystemOnTptp.Provers do
  @moduledoc """
  Stateful `Agent` that caches the list of prover identifiers currently
  advertised by a SystemOnTPTP deployment.

  The initial refresh is triggered in the background once the agent starts, so
  application boot is never blocked on an HTTP call. Callers can force a
  synchronous refresh via `refresh_systems_list/0` before using
  `get_systems_list/0`.
  """
  use Agent

  require Logger

  alias AtpClient.Config

  # The "ListSystems" request also includes type checkers etc.
  # We keep a whitelist for filtering.
  @known_systems [
    "Alt-Ergo",
    "Beagle",
    "Bliksem",
    "ConnectPP",
    "CSE_E",
    "CSI_Enigma",
    "CLI_V",
    "cvc5",
    "cvc5-SAT",
    "Darwin",
    "DarwinFM",
    "DLash",
    "Drodi",
    "DT2H2X",
    "Duper",
    "E",
    "E-Darwin",
    "E-SAT",
    "Enigma",
    "EQP",
    "Equinox",
    "Etableau",
    "FEST",
    "G4Plus",
    "Geo-III",
    "GKC",
    "Goeland",
    "GrAnDe",
    "HOLyHammer",
    "hopCoP",
    "Imogen",
    "Infinox",
    "iProver",
    "iProver-Eq",
    "iProver-SAT",
    "iProverMo",
    "KSP",
    "Lash",
    "lazyCoP",
    "leanCoP",
    "LEO-II",
    "Leo-III",
    "LisaTT",
    "Mace4",
    "MeadMax",
    "Matita",
    "Metis",
    "Moca",
    "MoMo",
    "Muscadet",
    "nanoCoP",
    "Otter",
    "Paradox",
    "Princess",
    "Prover9",
    "PyRes",
    "RPx",
    "Satallax",
    "SATCoP",
    "Scavenger",
    "SnakeForV",
    "SnakeForV-SAT",
    "SNARK",
    "SPASS+T",
    "SPASS",
    "ToFoF",
    "ToFoF-SAT",
    "Toma",
    "Twee",
    "Vampire",
    "Vampire-FMo",
    "Vampire-LIT",
    "Vampire-SAT",
    "Vampire-SATLIT",
    "Waldmeister",
    "Z3",
    "Zenon",
    "ZenonModulo",
    "Zipperpin"
  ]

  @doc """
  Links the module as an `Agent` process with the caller process and
  schedules a background refresh of the system list.
  """
  @spec start_link(any()) :: {:ok, pid()} | {:error, any()}
  def start_link(_args) do
    with {:ok, pid} <- Agent.start_link(fn -> [] end, name: __MODULE__) do
      Task.start(&refresh_or_warn/0)

      {:ok, pid}
    end
  end

  defp refresh_or_warn do
    case refresh_systems_list() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("AtpClient.TptpSystems: initial refresh failed: #{inspect(reason)}")
    end
  end

  @doc """
  Returns a cached list of the available provers (e.g. "cvc5---1.3.0").

  Returns `[]` until the first successful refresh completes.
  """
  @spec get_systems_list() :: [String.t()]
  def get_systems_list do
    Agent.get(__MODULE__, & &1)
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

    payload =
      URI.encode_query(%{
        "SubmitButton" => "ListSystems",
        "ListStatus" => "READY",
        "QuietFlag" => "-q0",
        "NoHTML" => "1"
      })

    case Req.post(url, body: payload, receive_timeout: timeout_ms) do
      {:ok, %{status: 200, body: body}} ->
        systems_online =
          body
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.contains?(&1, "---"))
          |> Enum.uniq()
          |> Enum.filter(fn system ->
            Enum.any?(@known_systems, &String.starts_with?(system, &1 <> "---"))
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
