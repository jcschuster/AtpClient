defmodule AtpClient.Lint.Tptp4x do
  @moduledoc """
  Authoritative TPTP syntax and type checker, delegated to TPTP4x on the
  SystemOnTPTP deployment.

  Shares the same endpoint and form convention as `AtpClient.SystemOnTptp`
  — the TPTP4x tool is exposed as a pseudo-prover on the form, so we
  reuse the configured `:url` rather than introducing a second endpoint.
  The system identifier is `TPTP4x---0.0` (note the lowercase `x` and
  the two-part version).

  When the input parses cleanly, TPTP4x echoes a normalised form of the
  problem and this module returns `{:ok, []}`. When it doesn't, TPTP4x
  emits `ERROR:` / `WARNING:` lines (usually with a `line N, column M`
  suffix), and we translate those into `Diagnostic`s. Unrecognised error
  formats fall back to a single line-1 diagnostic carrying the raw TPTP4x
  output so the user can still see what the tool complained about —
  better than silently dropping information during a live demo.
  """

  alias AtpClient.Config
  alias AtpClient.Lint.Diagnostic

  # Matches TPTP4X diagnostic lines of the form
  #
  #     ERROR: <message> at line <N>, column <M>
  #     WARNING: <message> at line <N>
  #     ERROR: <message>
  @diag_re ~r/^(?<sev>ERROR|WARNING|INFO)\s*:\s*(?<msg>.+?)(?:\s+at\s+line\s+(?<line>\d+)(?:\s*,\s*column\s+(?<col>\d+))?)?\s*$/

  # SZS status signalling a (non-)successful parse.
  @szs_re ~r/SZS\s+status\s+(?<status>\w+)/

  @doc """
  Runs TPTP4X on `problem` via the configured SystemOnTPTP endpoint.

  ## Options

    * `:url` — override the endpoint URL. Defaults to the value configured
      under `config :atp_client, :sotptp, :url`;
    * `:tptp4x_system` — override the TPTP4X system identifier (default
      `"TPTP4X---0.0"`). Configurable because the identifier occasionally
      shifts with TPTP deployments;
    * `:tptp4x_time_limit_sec` — server-side time limit (default `10`);
    * `:request_timeout_ms` — HTTP receive timeout (default
      `(tptp4x_time_limit_sec + 5) * 1000`).
  """
  @spec check(String.t(), keyword()) :: {:ok, [Diagnostic.t()]} | {:error, term()}
  def check(problem, opts \\ []) when is_binary(problem) do
    url = Config.fetch!(:sotptp, :url, opts)
    system = Config.fetch(:sotptp, :tptp4x_system, "TPTP4X---0.0", opts)
    time_limit = Config.fetch(:sotptp, :tptp4x_time_limit_sec, 10, opts)

    timeout_ms =
      Keyword.get(opts, :request_timeout_ms, (time_limit + 5) * 1000)

    payload =
      URI.encode_query(%{
        "SubmitButton" => "RunSelectedSystems",
        "ProblemSource" => "FORMULAE",
        "FORMULAEProblem" => problem,
        "NoHTML" => "1",
        "QuietFlag" => "-q01",
        "X2TPTP" => "-S",
        ("System___" <> system) => system,
        ("TimeLimit___" <> system) => Kernel.to_string(time_limit)
      })

    case Req.post(url, body: payload, receive_timeout: timeout_ms) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_output(body)}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- output parsing -----------------------------------------------------

  @doc false
  # Exposed for tests — not part of the public API.
  @spec parse_output(String.t()) :: [Diagnostic.t()]
  def parse_output(body) when is_binary(body) do
    lines = String.split(body, ~r/\r?\n/)

    structured =
      lines
      |> Enum.flat_map(&parse_line/1)

    cond do
      structured != [] ->
        structured

      syntax_error_status?(body) ->
        [fallback_diagnostic(body)]

      true ->
        []
    end
  end

  defp parse_line(line) do
    case Regex.named_captures(@diag_re, line) do
      %{"sev" => sev, "msg" => msg, "line" => l, "col" => c} ->
        [
          %Diagnostic{
            line: parse_int(l, 1),
            column: parse_int(c, 1),
            severity: severity(sev),
            message: String.trim(msg),
            source: "tptp4x"
          }
        ]

      _ ->
        []
    end
  end

  defp syntax_error_status?(body) do
    case Regex.named_captures(@szs_re, body) do
      %{"status" => status} ->
        status in ~w(SyntaxError InputError Error)

      _ ->
        false
    end
  end

  # Build a single diagnostic from the most "interesting" line of the
  # response body — either the SZS status line or the first line
  # containing `ERROR`/`error` — so the user sees *something* even when
  # the output format doesn't match our regex.
  defp fallback_diagnostic(body) do
    message =
      body
      |> String.split(~r/\r?\n/)
      |> Enum.find(fn line ->
        String.contains?(line, "SZS status") or
          String.match?(line, ~r/\b(ERROR|error)\b/)
      end)
      |> case do
        nil -> "TPTP4X reported an issue (see server output for details)"
        line -> String.trim(line)
      end

    %Diagnostic{
      line: 1,
      column: 1,
      severity: :error,
      message: message,
      source: "tptp4x"
    }
  end

  defp parse_int("", default), do: default
  defp parse_int(nil, default), do: default

  defp parse_int(s, default) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  defp severity("ERROR"), do: :error
  defp severity("WARNING"), do: :warning
  defp severity("INFO"), do: :info
  defp severity(_), do: :info
end
