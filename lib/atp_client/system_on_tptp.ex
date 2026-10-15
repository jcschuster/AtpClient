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
      # advertises; an identifier from systems/1 names one exactly.
      {:ok, result} = AtpClient.SystemOnTptp.query_system(thf_problem, "Vampire")
      result.status   # => :theorem
      result.system   # => "Vampire---5.0.1"
      result.output   # => the prover's stdout as SystemOnTPTP relayed it

  ## Systems

  SystemOnTPTP identifies a system as `<name>---<version>` and keeps only the
  current version of each, so a version string in a caller's code goes stale
  with the next deployment. Every function here takes a bare name as well and
  resolves it to the latest version advertised, through
  `AtpClient.SystemOnTptp.Systems.resolve/2`; an identifier is checked as
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
  alias AtpClient.Input
  alias AtpClient.Result
  alias AtpClient.SystemOnTptp.Reply
  alias AtpClient.SystemOnTptp.SystemInfo
  alias AtpClient.SystemOnTptp.Systems
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
                 x2tptp: [
                   type: :boolean,
                   doc:
                     "Ask for the reply as TSTP solution files (`X2TPTP=-S`, default " <>
                       "`true`); `false` asks for the systems' raw output."
                 ],

                 # Per-call ephemera.
                 input_format: [
                   type: :string,
                   doc: "`process_problem/3`: the `InputFormat` field (default `\"TPTP\"`)."
                 ],
                 solution_format: [
                   type: :string,
                   doc: "`process_solution/3`: the `SolutionFormat` field (default `\"TPTP\"`)."
                 ],
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
                       "`\"tptp:raw\"`). Unknown values are not reliably rejected: SotP may " <>
                       "reply `ERROR: Formatter did not create ...` or run the system on a " <>
                       "truncated problem — pick from the values shown in the SystemOnTPTP " <>
                       "form for the target system."
                 ],
                 transform: [
                   type: :string,
                   doc:
                     "Overrides the per-system `Transform___<sysid>` form field (e.g. " <>
                       "`\"none\"`). SotP replies `ERROR: Formatter did not create ...` to an " <>
                       "unknown value."
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
        doc: "System name or identifier (see systems/1) used by query/2."
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
      },
      %Field{
        key: :x2tptp,
        type: :boolean,
        required?: false,
        group: :defaults,
        default: true,
        label: "TSTP replies",
        doc:
          "Ask SystemOnTPTP to reply with one TSTP solution file per system " <>
            "(X2TPTP=-S). The derivation is then in `details.tstp`; off, the " <>
            "reply is the systems' raw output."
      }
    ]
  end

  @impl AtpClient.Backend
  def verify(opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)

    case SystemInfo.list_systems(opts) do
      {:ok, [_ | _]} -> :ok
      {:ok, []} -> {:error, :no_systems}
      {:error, _} = err -> err
    end
  end

  @impl AtpClient.Backend
  @spec query(Input.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def query(problem, opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)
    system = Config.fetch(:sotptp, :default_system, "E", opts)
    query_system(problem, system, opts)
  end

  @doc """
  The identifiers of the systems with the `:prove` capability.
  """
  @deprecated "Use AtpClient.SystemOnTptp.systems(capability: :prove)"
  @spec list_provers() :: [String.t()]
  def list_provers, do: provers()

  defp provers, do: for(system <- Systems.systems(capability: :prove), do: system.id)

  @doc """
  The systems the deployment offers, as `AtpClient.System` records, filtered by
  `capability:`, `interface:`, `dialect:` (a `t:Tptp.Query.dialect/0` the system's
  SPCs name), `spc:` (an exact SPC word) and `name:`; see
  `AtpClient.SystemOnTptp.Systems.systems/1`.

      AtpClient.SystemOnTptp.systems(capability: :find_model, dialect: :fof)
  """
  @spec systems([Systems.filter()]) :: [AtpClient.System.t()]
  def systems(filters \\ []), do: Systems.systems(filters)

  @doc """
  Queries one system via SystemOnTPTP, given by name (`"E"`) or identifier
  (`"E---3.5.1"`); see "Systems" in the module documentation. Available
  systems can be looked up with `systems/1`. The problem is an
  `AtpClient.Input` in a dialect the selected system accepts
  (`AtpClient.System.dialects/1`; it is not checked here); SystemOnTPTP
  resolves `include` directives against its own copy of the TPTP library, so a
  `Tptp.File` is sent as it is.

  Returns `{:error, {:unknown_system, system}}` without a round-trip when the
  system is not advertised, and `{:error, {:not_offered, id, :system_on_tptp}}`
  when its record says it is not a SystemOnTPTP system (a tool such as GDV is
  run with `process_solution/3`, a converter with `process_problem/3`).

  The response body — the system's stdout as SystemOnTPTP relays it — is read
  by `AtpClient.Verdict` and kept on the result as `output`.

  ## Options

    * `:time_limit_sec` — time limit in seconds (default `5`);
    * `:url` — override the SystemOnTPTP endpoint URL;
    * `:command`, `:format`, `:transform` — per-system SotP form overrides
      (`Command___<sysid>`, `Format___<sysid>`, `Transform___<sysid>`). Each
      is transmitted only when set. `:format` and `:transform` are honoured
      by tptp.org. An unknown transform makes SotP reply with
      `ERROR: Formatter did not create ...`, read as `{:error,
      {:unrecognized_output, body}}`; an unknown format, for a multi-line
      problem, runs the system on a truncated file. `:command` is transmitted for
      compatibility with self-hosted SotP deployments but the tptp.org
      public endpoint currently ignores it and runs its own wrapper.

  ## Cancellation

  SystemOnTPTP has no remote-cancel endpoint. If the calling process dies
  the Finch connection is released locally, but the prover **runs to its
  `TimeLimit` on the server**. Set `:time_limit_sec` to bound the server-
  side work; that is the only knob available.
  """
  @spec query_system(Input.t(), String.t(), Keyword.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def query_system(problem, system, opts \\ []) when is_binary(system) do
    NimbleOptions.validate!(opts, @opts_schema)

    run(problem, system, :system_on_tptp, run_fields(opts), opts)
  end

  @doc """
  Runs a problem tool — a converter such as ECNF or Monotonox-2FOF, an axiom
  selector such as Prophet, a checker such as BNFParser — on `input` through
  SystemB4TPTP (`SubmitButton=ProcessProblem`).

  The system is given and resolved as for `query_system/3`, and must be offered
  through `:system_b4_tptp`; otherwise `{:error, {:not_offered, id,
  :system_b4_tptp}}` without a round-trip. A converter's reply is a `Success`
  status with a `ListOf…` block, read by `AtpClient.Result.formulae/1`:

      {:ok, result} = AtpClient.SystemOnTptp.process_problem(problem, "ECNF")
      {:ok, clauses, _diagnostics} = AtpClient.Result.formulae(result)

  ## Options

  Those of `query_system/3`, and `:input_format`, the `InputFormat` field
  (default `"TPTP"`).
  """
  @spec process_problem(Input.t(), String.t(), Keyword.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def process_problem(input, system, opts \\ []) when is_binary(system) do
    NimbleOptions.validate!(opts, @opts_schema)

    fields = [
      {"SubmitButton", "ProcessProblem"},
      {"InputFormat", Keyword.get(opts, :input_format, "TPTP")}
    ]

    run(input, system, :system_b4_tptp, fields, opts)
  end

  @doc """
  Runs a solution tool — a verifier such as GDV or AGMV, a viewer, a
  statistics tool — on `input`, a derivation or an interpretation, through
  SystemOnTSTP (`SubmitButton=ProcessSolution`).

  The system must be offered through `:system_on_tstp`; otherwise `{:error,
  {:not_offered, id, :system_on_tstp}}` without a round-trip. GDV answers
  `VerifiedGood` or `VerifiedBad`; a verifier whose record says it prints a
  word outside the ontology — AGMV's maps `VerifiedGood` to `SZS status
  Verified` — is read through its own `Solved` patterns (see
  `AtpClient.Verdict`). No `Verified` reply from AGMV has been captured yet
  (`test/fixtures/README.md`). `AtpClient.verify/2` picks the verifier.

  The solution is sent as `FORMULAE`, which has no slot for the problem it
  solves: GDV then warns `No problem file` and its leaf verification is
  incomplete. Full verification against a TPTP library problem
  (`ProblemSource=TSTP`) is not offered yet.

  ## Options

  Those of `query_system/3`, and `:solution_format`, the `SolutionFormat` field
  (default `"TPTP"`).
  """
  @spec process_solution(Input.t(), String.t(), Keyword.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def process_solution(input, system, opts \\ []) when is_binary(system) do
    NimbleOptions.validate!(opts, @opts_schema)

    fields = [
      {"SubmitButton", "ProcessSolution"},
      {"SolutionFormat", Keyword.get(opts, :solution_format, "TPTP")}
    ]

    run(input, system, :system_on_tstp, fields, opts)
  end

  # One system, one round-trip: resolve, check the interface, post, read.
  defp run(input, system, interface, fields, opts) do
    with {:ok, id} <- Systems.resolve(system),
         :ok <- offered(id, interface),
         {:ok, body} <- post(input, [id], fields, opts) do
      case Reply.sections(body) do
        [] -> Verdict.interpret(body, __MODULE__, [system: id] ++ Systems.verdict_options(id))
        sections -> read_section(id, section_for(sections, id))
      end
    end
  end

  # A system the loaded records do not know — none loaded, or the identifier
  # passed through — is let through: the deployment is the judge.
  @spec offered(String.t(), AtpClient.System.interface()) ::
          :ok | {:error, {:not_offered, String.t(), AtpClient.System.interface()}}
  defp offered(id, interface) do
    case Systems.get(id) do
      %AtpClient.System{interfaces: interfaces} = system ->
        if interface in interfaces, do: :ok, else: {:error, {:not_offered, system.id, interface}}

      nil ->
        :ok
    end
  end

  defp run_fields(opts), do: [{"SubmitButton", "RunSelectedSystems"} | x2tptp(opts)]

  # The section a single-system reply holds for `id`, or the only one there is.
  defp section_for(sections, id) do
    case List.keyfind(sections, id, 0) do
      {^id, text} -> text
      nil -> sections |> hd() |> elem(1)
    end
  end

  @doc """
  Reads one section of a reply, as `AtpClient.SystemOnTptp.Reply.sections/1`
  returns it, for system `id`.

  A TSTP section is read by `Tptp.Tstp.from_string/2`: `AtpClient.Verdict`
  reads the archived system output, `solution.original`, and when that holds no
  status the result is the header's `Result` with `evidence: {:tstp, "Result"}`.
  The solution is `details.tstp` and the blocks are those of `original`. A raw
  section is read by `AtpClient.Verdict` as it is. Either way `output` is the
  section's text, and the system's `Solved` patterns are passed along when its
  record is loaded.
  """
  @spec read_section(String.t(), binary()) :: {:ok, Result.t()} | {:error, Verdict.failure()}
  def read_section(id, text) when is_binary(id) and is_binary(text) do
    fields = [system: id] ++ Systems.verdict_options(id)

    case Tptp.Tstp.from_string(text) do
      {:ok, solution, _diagnostics} ->
        original = solution.original || ""

        case Verdict.interpret(original, __MODULE__, fields) do
          {:error, {:unrecognized_output, _}} when solution.result != nil ->
            {:ok,
             %Result{
               status: solution.result,
               evidence: {:tstp, "Result"},
               output: text,
               backend: __MODULE__,
               system: id,
               problem: Tptp.Tstp.Solution.problem(solution),
               blocks: Tptp.Szs.blocks(original),
               details: %{tstp: solution}
             }}

          {:ok, result} ->
            {:ok, %{result | output: text, details: Map.put(result.details, :tstp, solution)}}

          {:error, _} = error ->
            error
        end

      {:error, :not_tstp} ->
        Verdict.interpret(text, __MODULE__, fields)
    end
  end

  # One form-reply round-trip for the given system identifiers, with the
  # receive timeout scaled by their number.
  @spec post(Input.t(), [String.t()], [{String.t(), String.t()}], keyword()) ::
          {:ok, binary()} | {:error, term()}
  defp post(problem, ids, fields, opts) do
    url = Config.fetch!(:sotptp, :url, opts)

    time_limit_sec =
      Keyword.get(opts, :time_limit_sec) ||
        Config.fetch(:sotptp, :default_time_limit_sec, 5)

    network_overhead_ms = Config.fetch(:sotptp, :network_overhead_ms, 30_000, opts)

    case Req.post(
           url,
           form: build_form(problem, ids, fields, time_limit_sec, opts),
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

  # Builds the urlencoded form for a SotP FormReply POST: `fields` (the submit
  # button and what goes with it) first, then the problem. The per-system
  # field cluster (`System___`, `TimeLimit___`, plus the `Command___` /
  # `Format___` / `Transform___` overrides when set) is emitted once per
  # system id; the same override values apply to every system in a
  # multi-system call. The form is a list, not a map: SystemOnTPTP runs the
  # systems in field order and reports them in that order, and a map would
  # sort the fields by name.
  defp build_form(problem, system_ids, fields, time_limit_sec, opts) do
    time_str = Integer.to_string(time_limit_sec)
    text = problem |> Input.to_iodata() |> IO.iodata_to_binary()

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

    fields ++
      [
        {"ProblemSource", "FORMULAE"},
        {"FORMULAEProblem", text},
        {"NoHTML", "1"},
        {"QuietFlag", "-q01"}
        | system_fields
      ]
  end

  defp x2tptp(opts) do
    if Config.fetch(:sotptp, :x2tptp, true, opts), do: [{"X2TPTP", "-S"}], else: []
  end

  @doc """
  Makes a single request to SystemOnTPTP to run all given systems with default
  arguments. Accepted options are the same as for `query_system/3`; the
  `:command`, `:format`, and `:transform` overrides — if set — are applied
  identically to every system in `systems`.

  Returns one `{system, outcome}` per system given, in the order given, where
  `system` is the resolved identifier and `outcome` is what `read_section/2`
  read from that system's section of the reply. A system that is not advertised
  is `{name, {:error, {:unknown_system, name}}}`, and one whose record says it is
  not offered through SystemOnTPTP is `{id, {:error, {:not_offered, id,
  :system_on_tptp}}}`; neither is submitted. One the deployment accepted but
  returned no section for is
  `{id, {:error, :no_output}}`. Only the outer `{:error, reason}` is a failed
  request.
  """
  @spec query_selected_systems(Input.t(), [String.t()], Keyword.t()) ::
          {:ok, [{String.t(), {:ok, Result.t()} | {:error, term()}}]}
          | {:error, term()}
  def query_selected_systems(problem, systems, opts \\ []) when is_list(systems) do
    NimbleOptions.validate!(opts, @opts_schema)
    resolved = Enum.map(systems, &selected/1)

    ids = for {_given, {:ok, id}} <- resolved, uniq: true, do: id

    with {:ok, sections} <- sections(problem, ids, opts) do
      {:ok,
       Enum.map(resolved, fn
         {_given, {:ok, id}} -> {id, Map.get(sections, id, {:error, :no_output})}
         {given, {:error, _reason} = error} -> {given, error}
       end)}
    end
  end

  # A system given to `query_selected_systems/3`: resolved and offered, or the
  # reason it is not submitted, under the name it was given or resolved to.
  defp selected(given) do
    with {:ok, id} <- Systems.resolve(given),
         :ok <- offered(id, :system_on_tptp) do
      {given, {:ok, id}}
    else
      {:error, {:not_offered, id, _interface}} = error -> {id, error}
      {:error, _reason} = error -> {given, error}
    end
  end

  # The reply, one section per system the deployment ran, keyed by the
  # identifier each section names. No round-trip for no systems.
  @spec sections(Input.t(), [String.t()], keyword()) ::
          {:ok, %{String.t() => {:ok, Result.t()} | {:error, Verdict.failure()}}}
          | {:error, term()}
  defp sections(_problem, [], _opts), do: {:ok, %{}}

  defp sections(problem, ids, opts) do
    with {:ok, body} <- post(problem, ids, run_fields(opts), opts) do
      {:ok, Map.new(Reply.sections(body), fn {id, text} -> {id, read_section(id, text)} end)}
    end
  end

  @doc """
  Queries all available provers on SystemOnTPTP and returns results from systems
  that did not error out. Returns a list of tuples `{system_id, result}`.

  All options accepted by `query_selected_systems/3` are forwarded.
  """
  @spec query_all_systems(Input.t(), Keyword.t()) ::
          {:ok, [{String.t(), {:ok, Result.t()} | {:error, term()}}]}
          | {:error, term()}
  def query_all_systems(problem, opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)
    query_selected_systems(problem, provers(), opts)
  end
end
