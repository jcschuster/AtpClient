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

      # system IDs returned by list_provers/0, e.g. "Vampire-FMo---5.0.1"
      {:ok, result} = AtpClient.SystemOnTptp.query_system(thf_problem, "Vampire-FMo---5.0.1")
      # => {:ok, :theorem}

  ## Cancellation

  SystemOnTPTP exposes no remote cancellation endpoint — the form submits a
  problem and the server runs the prover to its `TimeLimit`, returning the
  prover stdout in the HTTP response. When the calling BEAM process dies
  the in-flight `Req`/`Finch` request errors out and the connection slot is
  released, but the **remote prover continues to its `TimeLimit`**. The
  only server-side bound on cancelled work is the `:time_limit_sec` option
  passed to `query_system/3`.
  """

  @behaviour AtpClient.Backend

  alias AtpClient.Config
  alias AtpClient.Config.Field
  alias AtpClient.SystemOnTptp.Provers
  alias AtpClient.ResultNormalization, as: RN

  # Every key any function in this module reads out of `opts` — plus the
  # per-system overrides the tptp.org form exposes. Validated at every
  # public entry point via `NimbleOptions.validate!/2`, so unknown keys
  # (typos like `:time_limit` for `:time_limit_sec`) raise instead of
  # silently no-opping.
  @opts_schema NimbleOptions.new!(
                 # Schema-declared connection / defaults (see `config_schema/0`).
                 url: [type: :string],
                 default_system: [type: :string],
                 default_time_limit_sec: [type: :non_neg_integer],
                 network_overhead_ms: [type: :non_neg_integer],
                 refresh_timeout_ms: [type: :non_neg_integer],

                 # Per-call ephemera.
                 time_limit_sec: [
                   type: :non_neg_integer,
                   doc: "Prover CPU time limit in seconds; overrides `:default_time_limit_sec`."
                 ],
                 raw: [
                   type: :boolean,
                   doc:
                     "When `true`, return `{:ok, body_string}` instead of the classified " <>
                       "`atp_result()`. `query/2` (Backend entry point) forces this to `false`."
                 ],
                 command: [
                   type: :string,
                   doc:
                     "Overrides the per-system `Command___<sysid>` form field (the wrapper " <>
                       "script line SotP will run). NOTE: tptp.org's public FormReply " <>
                       "endpoint currently ignores this field — a manual probe with a " <>
                       "`/nonexistent/binary` override still ran the default wrapper — but " <>
                       "self-hosted SotP deployments may honour it, so it is transmitted."
                 ],
                 format: [
                   type: :string,
                   doc:
                     "Overrides the per-system `Format___<sysid>` form field (e.g. " <>
                       "`\"tptp:raw\"`). Unknown values cause SotP to reply with " <>
                       "`ERROR: Formatter did not create ...` — pick from the values shown " <>
                       "in the SystemOnTPTP form for the target system."
                 ],
                 transform: [
                   type: :string,
                   doc:
                     "Overrides the per-system `Transform___<sysid>` form field (e.g. " <>
                       "`\"none\"`). Unknown values are rejected the same way `:format` is."
                 ]
               )

  @impl AtpClient.Backend
  def config_key, do: :sotptp

  @impl AtpClient.Backend
  def label, do: "SystemOnTPTP"

  @impl AtpClient.Backend
  def config_schema do
    [
      %Field{
        key: :url,
        type: :string,
        required?: true,
        group: :connection,
        default: "https://tptp.org/cgi-bin/SystemOnTPTPFormReply",
        label: "Endpoint URL",
        doc: "SystemOnTPTP form-reply endpoint."
      },
      %Field{
        key: :default_system,
        type: :string,
        required?: false,
        group: :defaults,
        label: "Default system",
        doc: "System ID (see list_provers/0) used by query/2."
      },
      %Field{
        key: :default_time_limit_sec,
        type: :integer,
        required?: false,
        group: :defaults,
        default: 5,
        label: "Default time limit (s)"
      },
      %Field{
        key: :network_overhead_ms,
        type: :integer,
        required?: false,
        group: :connection,
        default: 30_000,
        label: "Network overhead (ms)",
        doc:
          "Padding added to the prover time limit when computing the HTTP " <>
            "receive timeout. Covers server-side form handling and network " <>
            "latency; SystemOnTPTP's baseline round-trip has been observed " <>
            "around 13 s."
      }
    ]
  end

  @impl AtpClient.Backend
  def verify(opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)

    case Provers.refresh_systems_list(opts) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @impl AtpClient.Backend
  @spec query(String.t(), keyword()) :: RN.atp_result() | {:error, term()}
  def query(problem, opts \\ []) when is_binary(problem) do
    NimbleOptions.validate!(opts, @opts_schema)
    system_id = Config.fetch!(:sotptp, :default_system, opts)
    # Force non-raw so query_system/3 returns an atp_result() and not a body.
    query_system(problem, system_id, Keyword.put(opts, :raw, false))
  end

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
    * `:raw` — when `true`, skip `interpret_result/1` and return the raw
      HTTP response body (the prover's stdout as SystemOnTPTP relays it)
      as `{:ok, body_string}`. Default `false`;
    * `:url` — override the SystemOnTPTP endpoint URL;
    * `:command`, `:format`, `:transform` — per-system SotP form overrides
      (`Command___<sysid>`, `Format___<sysid>`, `Transform___<sysid>`). Each
      is transmitted only when set. `:format` and `:transform` are honoured
      by tptp.org — passing an unknown module name causes SotP to reply with
      `ERROR: Formatter did not create ...`. `:command` is transmitted for
      compatibility with self-hosted SotP deployments but the tptp.org
      public endpoint currently ignores it and runs its own wrapper.

  ## Cancellation

  SystemOnTPTP has no remote-cancel endpoint. If the calling process dies
  the Finch connection is released locally, but the prover **runs to its
  `TimeLimit` on the server**. Set `:time_limit_sec` to bound the server-
  side work; that is the only knob available.
  """
  @spec query_system(String.t(), String.t(), Keyword.t()) ::
          {:ok, String.t()} | RN.atp_result() | {:error, term()}
  def query_system(problem, system_id, opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)
    url = Config.fetch!(:sotptp, :url, opts)

    time_limit_sec =
      Keyword.get(opts, :time_limit_sec) ||
        Config.fetch(:sotptp, :default_time_limit_sec, 5)

    network_overhead_ms = Config.fetch(:sotptp, :network_overhead_ms, 30_000, opts)
    return_raw = Keyword.get(opts, :raw, false)

    case Req.post(
           url,
           form: build_form(problem, [system_id], time_limit_sec, opts),
           finch: AtpClient.TptpFinch,
           compressed: false,
           receive_timeout: time_limit_sec * 1000 + network_overhead_ms,
           retry: :transient,
           retry_delay: fn _ -> 500 end
         ) do
      {:ok, %{status: 200, body: body}} ->
        if return_raw, do: {:ok, body}, else: RN.interpret_result(body)

      {:ok, %{status: status}} ->
        {:error, "API Error: status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Builds the multipart/urlencoded form for a SotP FormReply POST. The
  # per-system field cluster (`System___`, `TimeLimit___`, plus the
  # `Command___`/`Format___`/`Transform___` overrides when set) is emitted
  # once per `system_id`; the same override values apply to every system
  # in a multi-system call.
  defp build_form(problem, system_ids, time_limit_sec, opts) do
    time_str = Integer.to_string(time_limit_sec)

    per_system_overrides =
      [
        {"Command___", Keyword.get(opts, :command)},
        {"Format___", Keyword.get(opts, :format)},
        {"Transform___", Keyword.get(opts, :transform)}
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    system_fields =
      Enum.flat_map(system_ids, fn sysid ->
        base = [
          {"System___" <> sysid, sysid},
          {"TimeLimit___" <> sysid, time_str}
        ]

        overrides = Enum.map(per_system_overrides, fn {prefix, v} -> {prefix <> sysid, v} end)
        base ++ overrides
      end)

    Enum.into(system_fields, %{
      "SubmitButton" => "RunSelectedSystems",
      "ProblemSource" => "FORMULAE",
      "FORMULAEProblem" => problem,
      "NoHTML" => "1",
      "QuietFlag" => "-q01",
      "X2TPTP" => "-S"
    })
  end

  @doc """
  Makes a single request to SystemOnTPTP to run all given systems with default
  arguments. Accepted options are the same as for `query_system/3`; the
  `:command`, `:format`, and `:transform` overrides — if set — are applied
  identically to every system in `system_ids`.
  """
  @spec query_selected_systems(String.t(), [String.t()], Keyword.t()) ::
          {:ok, [{String.t(), RN.atp_result()}]}
          | {:ok, [{String.t(), String.t()}]}
          | {:error, term()}
  def query_selected_systems(problem, system_ids, opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)
    url = Config.fetch!(:sotptp, :url, opts)

    time_limit_sec =
      Keyword.get(opts, :time_limit_sec) ||
        Config.fetch(:sotptp, :default_time_limit_sec, 5)

    network_overhead_ms = Config.fetch(:sotptp, :network_overhead_ms, 30_000, opts)
    return_raw = Keyword.get(opts, :raw, false)

    case Req.post(
           url,
           form: build_form(problem, system_ids, time_limit_sec, opts),
           finch: AtpClient.TptpFinch,
           compressed: false,
           receive_timeout: (time_limit_sec * 1000 + network_overhead_ms) * length(system_ids),
           retry: :transient,
           retry_delay: fn _ -> 500 end
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
    NimbleOptions.validate!(opts, @opts_schema)
    query_selected_systems(problem, list_provers(), opts)
  end
end
