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

      # A system name resolves to the version SystemOnTPTP currently
      # advertises; an identifier from list_provers/0 names one exactly.
      {:ok, result} = AtpClient.SystemOnTptp.query_system(thf_problem, "Vampire")
      result.status   # => :theorem
      result.system   # => "Vampire---5.0.1"
      result.output   # => the prover's stdout as SystemOnTPTP relayed it

  ## Systems

  SystemOnTPTP identifies a system as `<name>---<version>` and keeps only the
  current version of each, so a version string in a caller's code goes stale
  with the next deployment. Every function here takes a bare name as well and
  resolves it to the latest version advertised, through
  `AtpClient.SystemOnTptp.Provers.resolve/2`; an identifier is checked as
  written. A system that is neither is `{:error, {:unknown_system, name}}` and
  is not submitted — SystemOnTPTP stops processing a request at the first
  system it does not know, so an unknown one would silently take every system
  after it down with it.

  `query/2` runs `:default_system`, `"E"` unless configured otherwise.

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
  alias AtpClient.Problem
  alias AtpClient.Result
  alias AtpClient.SystemOnTptp.Provers
  alias AtpClient.Verdict

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
        default: "E",
        label: "Default system",
        doc: "System name or identifier (see list_provers/0) used by query/2."
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
  @spec query(Problem.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def query(problem, opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)
    system = Config.fetch(:sotptp, :default_system, "E", opts)
    query_system(problem, system, opts)
  end

  @doc """
  Returns a list with all available system identifiers from SystemOnTPTP that
  correspond to known provers. This excludes type checking systems etc. which
  also get returned by the API.
  """
  @spec list_provers() :: [String.t()]
  def list_provers, do: Provers.get_systems_list()

  @doc """
  Queries one system via SystemOnTPTP, given by name (`"E"`) or identifier
  (`"E---3.5.1"`); see "Systems" in the module documentation. Available
  systems can be looked up with `list_provers/0`. The problem is an
  `AtpClient.Problem` in a dialect the selected system accepts; SystemOnTPTP
  resolves `include` directives against its own copy of the TPTP library, so a
  `Tptp.File` is sent as it is.

  Returns `{:error, {:unknown_system, system}}` without a round-trip when the
  system is not advertised.

  The response body — the system's stdout as SystemOnTPTP relays it — is read
  by `AtpClient.Verdict` and kept on the result as `output`.

  ## Options

    * `:time_limit_sec` — time limit in seconds (default `5`);
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
  @spec query_system(Problem.t(), String.t(), Keyword.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def query_system(problem, system, opts \\ []) when is_binary(system) do
    NimbleOptions.validate!(opts, @opts_schema)

    with {:ok, id} <- Provers.resolve(system),
         {:ok, body} <- post(problem, [id], opts) do
      Verdict.interpret(body, __MODULE__, system: id)
    end
  end

  # One form-reply round-trip for the given system identifiers, with the
  # receive timeout scaled by their number.
  @spec post(Problem.t(), [String.t()], keyword()) :: {:ok, binary()} | {:error, term()}
  defp post(problem, ids, opts) do
    url = Config.fetch!(:sotptp, :url, opts)

    time_limit_sec =
      Keyword.get(opts, :time_limit_sec) ||
        Config.fetch(:sotptp, :default_time_limit_sec, 5)

    network_overhead_ms = Config.fetch(:sotptp, :network_overhead_ms, 30_000, opts)

    case Req.post(
           url,
           form: build_form(problem, ids, time_limit_sec, opts),
           finch: [name: AtpClient.TptpFinch],
           compressed: false,
           receive_timeout: (time_limit_sec * 1000 + network_overhead_ms) * length(ids),
           retry: :transient,
           retry_delay: fn _ -> 500 end
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "API Error: status #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Builds the urlencoded form for a SotP FormReply POST. The per-system
  # field cluster (`System___`, `TimeLimit___`, plus the `Command___` /
  # `Format___` / `Transform___` overrides when set) is emitted once per
  # system id; the same override values apply to every system in a
  # multi-system call. The form is a list, not a map: SystemOnTPTP runs the
  # systems in field order and reports them in that order, and a map would
  # sort the fields by name.
  defp build_form(problem, system_ids, time_limit_sec, opts) do
    time_str = Integer.to_string(time_limit_sec)
    text = problem |> Problem.to_iodata() |> IO.iodata_to_binary()

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

    [
      {"SubmitButton", "RunSelectedSystems"},
      {"ProblemSource", "FORMULAE"},
      {"FORMULAEProblem", text},
      {"NoHTML", "1"},
      {"QuietFlag", "-q01"},
      {"X2TPTP", "-S"}
      | system_fields
    ]
  end

  @doc """
  Makes a single request to SystemOnTPTP to run all given systems with default
  arguments. Accepted options are the same as for `query_system/3`; the
  `:command`, `:format`, and `:transform` overrides — if set — are applied
  identically to every system in `systems`.

  Returns one `{system, outcome}` per system given, in the order given, where
  `system` is the resolved identifier and `outcome` is what
  `AtpClient.Verdict.interpret/3` read from that system's output. A system
  that is not advertised is `{name, {:error, {:unknown_system, name}}}` and is
  not submitted; one the deployment accepted but returned no section for is
  `{id, {:error, :no_output}}`. Only the outer `{:error, reason}` is a failed
  request.
  """
  @spec query_selected_systems(Problem.t(), [String.t()], Keyword.t()) ::
          {:ok, [{String.t(), {:ok, Result.t()} | {:error, term()}}]}
          | {:error, term()}
  def query_selected_systems(problem, systems, opts \\ []) when is_list(systems) do
    NimbleOptions.validate!(opts, @opts_schema)
    resolved = Enum.map(systems, &{&1, Provers.resolve(&1)})
    ids = for {_given, {:ok, id}} <- resolved, uniq: true, do: id

    with {:ok, sections} <- sections(problem, ids, opts) do
      {:ok,
       Enum.map(resolved, fn
         {_given, {:ok, id}} -> {id, Map.get(sections, id, {:error, :no_output})}
         {given, {:error, _reason} = error} -> {given, error}
       end)}
    end
  end

  # SystemOnTPTP separates the systems' outputs with two full-width comment
  # rules.
  @section_separator String.duplicate("%" <> String.duplicate("-", 78) <> "\n", 2)

  # The reply, one section per system the deployment ran, keyed by the
  # identifier each section names. No round-trip for no systems.
  @spec sections(Problem.t(), [String.t()], keyword()) ::
          {:ok, %{String.t() => {:ok, Result.t()} | {:error, Verdict.failure()}}}
          | {:error, term()}
  defp sections(_problem, [], _opts), do: {:ok, %{}}

  defp sections(problem, ids, opts) do
    with {:ok, body} <- post(problem, ids, opts) do
      {:ok,
       body
       |> String.split(@section_separator)
       |> Enum.map(&String.trim/1)
       |> Enum.reject(&(&1 == ""))
       |> Map.new(&extract_system_result/1)}
    end
  end

  defp extract_system_result(output) do
    system_id =
      case Regex.run(~r/% File\s*:\s*([^\r\n]+)/, output) do
        [_, name] -> String.trim(name)
        nil -> "UnknownSystem"
      end

    {system_id, Verdict.interpret(output, __MODULE__, system: system_id)}
  end

  @doc """
  Queries all available provers on SystemOnTPTP and returns results from systems
  that did not error out. Returns a list of tuples `{system_id, result}`.

  All options accepted by `query_selected_systems/3` are forwarded.
  """
  @spec query_all_systems(Problem.t(), Keyword.t()) ::
          {:ok, [{String.t(), {:ok, Result.t()} | {:error, term()}}]}
          | {:error, term()}
  def query_all_systems(problem, opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)
    query_selected_systems(problem, list_provers(), opts)
  end
end
