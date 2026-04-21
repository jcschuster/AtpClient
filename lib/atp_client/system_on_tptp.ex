defmodule AtpClient.SystemOnTptp do
  @moduledoc """
  Public tptp.org HTTP form API; see `query_system/3` and `query_all_systems/2`.

  ## Configuration

      config :atp_client, :sotptp,
        url: "tptp.example.org/SystemOnTPTPFormReply",
        auto_refresh: true,
        refresh_timeout_ms: 100_000,
        default_time_limit_sec: 10

  ## Example

      thf_problem = \"\"\"
      thf(conj,conjecture,
        ![X: $o]: (X | ~X)
      ).
      \"\"\"

      {:ok, result} = AtpClient.SystemOnTptp.query_system(thf_problem, "Vampire-FMo---5.0")
      # => {:ok, :thm}
  """

  alias AtpClient.Config
  alias AtpClient.SystemOnTptp.Provers
  alias AtpClient.ResultNormalization, as: RN

  @doc """
  Returns a list with all available system identifiers from SystemOnTPTP that
  correspond to known provers. This excludes type checking systems etc. which
  also get returned by the API.
  """
  @spec list_provers() :: [String.t()]
  def list_provers, do: Provers.get_systems_list()

  @doc """
  Queries a specific system via SystemOnTPTP. Available systems can be looked
  up with `list_provers/0`. The problem is expected to be in valid TPTP format
  and compatible with the selected prover.

  ## Options

    * `:time_limit_sec` — time limit in seconds (default `5`);
    * `:raw` — return the raw prover output instead of interpreting it
      (default `false`);
    * `:url` — override the SystemOnTPTP endpoint URL.
  """
  @spec query_system(String.t(), String.t(), Keyword.t()) ::
          {:ok, String.t()} | RN.atp_result() | {:error, term()}
  def query_system(problem, system_id, opts \\ []) do
    url = Config.fetch!(:sotptp, :url, opts)

    time_limit_sec =
      Keyword.get(opts, :time_limit_sec) ||
        Config.fetch(:sotptp, :default_time_limit_sec, 5)

    return_raw = Keyword.get(opts, :raw, false)

    payload =
      URI.encode_query(%{
        "SubmitButton" => "RunSelectedSystems",
        "ProblemSource" => "FORMULAE",
        "FORMULAEProblem" => problem,
        "NoHTML" => "1",
        "QuietFlag" => "-q01",
        "X2TPTP" => "-S",
        ("System___" <> system_id) => system_id,
        ("TimeLimit___" <> system_id) => Kernel.to_string(time_limit_sec)
      })

    case Req.post(
           url,
           body: payload,
           receive_timeout: (time_limit_sec + 5) * 1000
         ) do
      {:ok, %{status: 200, body: body}} ->
        if return_raw, do: {:ok, body}, else: RN.interpret_result(body)

      {:ok, %{status: status}} ->
        {:error, "API Error: status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Makes a single request to SystemOnTPTP to run all given systems with default
  arguments. Accepted options are the same as for `query_system/3`.
  """
  @spec query_selected_systems(String.t(), [String.t()], Keyword.t()) ::
          {:ok, [{String.t(), RN.atp_result()}]}
          | {:ok, [{String.t(), String.t()}]}
          | {:error, term()}
  def query_selected_systems(problem, system_ids, opts \\ []) do
    url = Config.fetch!(:sotptp, :url, opts)

    time_limit_sec =
      Keyword.get(opts, :time_limit_sec) ||
        Config.fetch(:sotptp, :default_time_limit_sec, 5)

    return_raw = Keyword.get(opts, :raw, false)

    system_fields =
      system_ids
      |> Enum.flat_map(&[{"System___" <> &1, &1}, {"TimeLimit___" <> &1, time_limit_sec}])
      |> Map.new()

    payload =
      Map.merge(system_fields, %{
        "SubmitButton" => "RunSelectedSystems",
        "ProblemSource" => "FORMULAE",
        "FORMULAEProblem" => problem,
        "NoHTML" => "1",
        "QuietFlag" => "-q01",
        "X2TPTP" => "-S"
      })
      |> URI.encode_query()

    case Req.post(
           url,
           body: payload,
           receive_timeout: (time_limit_sec + 5) * 1000 * length(system_ids)
         ) do
      {:ok, %{status: 200, body: body}} ->
        outputs =
          String.split(
            body,
            "%------------------------------------------------------------------------------\n%------------------------------------------------------------------------------\n"
          )

        mapped_results =
          outputs
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&extract_system_result(&1, return_raw))

        {:ok, mapped_results}

      {:ok, %{status: status}} ->
        {:error, "API Error: status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_system_result(raw_res, return_raw) do
    system_id =
      case Regex.run(~r/% File\s*:\s*([^\r\n]+)/, raw_res) do
        [_, name] -> String.trim(name)
        nil -> "UnknownSystem"
      end

    formatted_res = if return_raw, do: raw_res, else: RN.interpret_result(raw_res)

    {system_id, formatted_res}
  end

  @doc """
  Queries all available provers on SystemOnTPTP and returns results from systems
  that did not error out. Returns a list of tuples `{system_id, result}`.

  All options accepted by `query_selected_systems/3` are forwarded.
  """
  @spec query_all_systems(String.t(), Keyword.t()) ::
          {:ok, [{String.t(), RN.atp_result()}]}
          | {:ok, [{String.t(), String.t()}]}
          | {:error, term()}
  def query_all_systems(problem, opts \\ []) do
    query_selected_systems(problem, list_provers(), opts)
  end
end
