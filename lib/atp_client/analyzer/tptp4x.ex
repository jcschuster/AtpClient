defmodule AtpClient.Analyzer.Tptp4x do
  @moduledoc """
  TPTP4X as a `Tptp.Analyzer`: syntax and type findings from the TPTP World's own
  checker, run on the configured SystemOnTPTP deployment.

  `Tptp.Lint` reads a file against the published BNF and the `:==` conditions,
  which is everything the grammar states. What it does not state is the typing of
  a formula against its declarations; TPTP4X checks that, so this analyzer runs
  it remotely and brings its messages back as `Tptp.Diagnostic`s with byte spans
  on the analysed source.

      analysis = Tptp.analyze(source)

      Tptp.Analyzer.run_all(analysis, [Tptp.Lint, AtpClient.Analyzer.Tptp4x])
      # [{:tptp_lint, [...]}, {:tptp4x, [...]}]

  An editor runs the remote pass only when the local one found no error, since
  the user will fix the local error first and TPTP4X's view of a file that does
  not parse adds noise:

      if Tptp.Diagnostic.any_errors?(analysis.diagnostics),
        do: [],
        else: AtpClient.Analyzer.Tptp4x.analyze(analysis, [])

  ## The remote call

  TPTP4X is exposed on the SystemOnTPTP form as a pseudo-system, so this module
  reuses the configured `:url` under `config :atp_client, :sotptp` rather than
  introducing a second endpoint. The identifier is `TPTP4X---0.0`; it is
  configurable because it has shifted between deployments.

  A clean file comes back as TPTP4X's normalised echo of it and yields no
  diagnostics. Otherwise TPTP4X prints `ERROR: Line N Char M …` and `WARNING: …`
  lines, which become diagnostics with the code `TPTP4X`, positioned by
  `Tptp.Span.offset/3`. A message TPTP4X positions outside the source is reported
  at offset 0 rather than dropped.

  ## Failure

  `analyze/2` returns `[]` when the deployment cannot be reached, since a network
  failure is not a finding about the file. `check/2` returns the failure as
  `{:error, reason}` for callers who want to show it.
  """

  @behaviour Tptp.Analyzer

  alias AtpClient.Config
  alias Tptp.Analysis
  alias Tptp.Diagnostic
  alias Tptp.Span

  @code "TPTP4X"

  @line ~r/^%?\s*(?<sev>ERROR|WARNING|INFO)\s*:\s*Line\s+(?<line>\d+)\s+Char\s+(?<col>\d+)\s+(?<msg>.+?)\s*$/

  @opts_schema NimbleOptions.new!(
                 url: [type: :string, doc: "The SystemOnTPTP form endpoint."],
                 tptp4x_system: [
                   type: :string,
                   doc: "The system identifier. Default `\"TPTP4X---0.0\"`."
                 ],
                 tptp4x_time_limit_sec: [
                   type: :non_neg_integer,
                   doc: "Server-side limit. Default `10`."
                 ],
                 request_timeout_ms: [
                   type: :non_neg_integer,
                   doc: "HTTP receive timeout. Default `(tptp4x_time_limit_sec + 5) * 1000`."
                 ]
               )

  @impl Tptp.Analyzer
  def id, do: :tptp4x

  @impl Tptp.Analyzer
  def label, do: "TPTP4X"

  @impl Tptp.Analyzer
  def dialects, do: :any

  @doc """
  TPTP4X's findings for the analysed source, or `[]` when it cannot be reached.

  `options` are those of `check/2`.
  """
  @impl Tptp.Analyzer
  @spec analyze(Analysis.t(), keyword()) :: [Diagnostic.t()]
  def analyze(%Analysis{} = analysis, options) do
    case check(analysis, options) do
      {:ok, diagnostics} -> diagnostics
      {:error, _reason} -> []
    end
  end

  @doc """
  Runs TPTP4X on the analysed source and returns its findings, or the reason the
  deployment could not be reached.

  ## Options

    * `:url` — the SystemOnTPTP form endpoint. Defaults to the value configured
      under `config :atp_client, :sotptp, :url`.
    * `:tptp4x_system` — the system identifier. Default `"TPTP4X---0.0"`.
    * `:tptp4x_time_limit_sec` — server-side limit. Default `10`.
    * `:request_timeout_ms` — HTTP receive timeout. Default
      `(tptp4x_time_limit_sec + 5) * 1000`.
  """
  @spec check(Analysis.t(), keyword()) :: {:ok, [Diagnostic.t()]} | {:error, term()}
  def check(%Analysis{} = analysis, options \\ []) do
    NimbleOptions.validate!(options, @opts_schema)
    url = Config.fetch!(:sotptp, :url, options)
    system = Config.fetch(:sotptp, :tptp4x_system, "TPTP4X---0.0", options)
    time_limit = Config.fetch(:sotptp, :tptp4x_time_limit_sec, 10, options)
    timeout_ms = Keyword.get(options, :request_timeout_ms, (time_limit + 5) * 1000)
    source = source(analysis)

    payload =
      URI.encode_query(%{
        "SubmitButton" => "RunSelectedSystems",
        "ProblemSource" => "FORMULAE",
        "FORMULAEProblem" => source,
        "NoHTML" => "1",
        "QuietFlag" => "-q01",
        "X2TPTP" => "-S",
        ("System___" <> system) => system,
        ("TimeLimit___" <> system) => Integer.to_string(time_limit)
      })

    case Req.post(url, body: payload, receive_timeout: timeout_ms) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse(body, analysis.line_index || Span.line_index(source), file_id(analysis))}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # TPTP4X's output lines to diagnostics against a line index. Exposed for tests.
  @spec parse(binary(), Span.line_index(), Span.file_id()) :: [Diagnostic.t()]
  def parse(body, line_index, file \\ 0) when is_binary(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&line(&1, line_index, file))
    |> Diagnostic.sort()
  end

  @spec line(binary(), Span.line_index(), Span.file_id()) :: [Diagnostic.t()]
  defp line(text, line_index, file) do
    case Regex.named_captures(@line, text) do
      %{"sev" => severity, "msg" => message, "line" => line, "col" => column} ->
        offset = offset(line_index, String.to_integer(line), String.to_integer(column))
        [Diagnostic.new(@code, severity(severity), Span.new(file, offset, 0), clean(message))]

      nil ->
        []
    end
  end

  @spec offset(Span.line_index(), integer(), integer()) :: non_neg_integer()
  defp offset(line_index, line, column) do
    case Span.offset(line_index, line, column) do
      {:ok, offset} -> offset
      :error -> 0
    end
  end

  @spec clean(binary()) :: binary()
  defp clean(message) do
    case Regex.run(~r/^Token\s+.+?\s+:\s+(.+)$/, message) do
      [_, tail] -> String.trim(tail)
      nil -> String.trim(message)
    end
  end

  @spec severity(binary()) :: Diagnostic.severity()
  defp severity("ERROR"), do: :error
  defp severity("WARNING"), do: :warning
  defp severity(_info), do: :info

  @spec source(Analysis.t()) :: binary()
  defp source(%Analysis{file: %Tptp.File{source: source}}), do: source
  defp source(%Analysis{file: %Tptp.Unit{} = unit}), do: unit.files[unit.root].source

  @spec file_id(Analysis.t()) :: Span.file_id()
  defp file_id(%Analysis{file: %Tptp.File{id: id}}), do: id
  defp file_id(%Analysis{file: %Tptp.Unit{root: root}}), do: root
end
