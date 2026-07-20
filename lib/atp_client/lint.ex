defmodule AtpClient.Lint do
  @moduledoc """
  Syntax and type diagnostics for TPTP input, aggregated across one or
  more backends.

  Two backends ship with this module:

    * `AtpClient.Lint.Local` — a pure-Elixir structural checker that runs
      in-process, catches common typos (unknown role, missing dot,
      mismatched brackets) and extracts type declarations for hover and
      completion data.
    * `AtpClient.Lint.Tptp4x` — delegates to TPTP4X on the configured
      SystemOnTPTP deployment for authoritative syntax and type analysis.

  The default configuration runs both: the local pass is essentially
  free, and when it finds an error the remote pass is skipped to save a
  round-trip. Editor integrations (see `KinoAtpClient.SystemOnTptp`) call
  `analyze/2` on every debounced keystroke.

  ## Example

      iex> %AtpClient.Lint.Report{diagnostics: diags, symbols: syms} =
      ...>   AtpClient.Lint.analyze("fof(a, axim, p).")
      iex> Enum.map(diags, & &1.message)
      ["unknown TPTP role `axim`; expected one of: axiom, hypothesis, ..."]
      iex> syms
      []
  """

  alias AtpClient.Lint.{Diagnostic, Report}

  @type backend :: :local | :tptp4x

  @default_backends [:local, :tptp4x]

  # `:backends` is the only key this module reads; everything else is
  # forwarded verbatim to `AtpClient.Lint.Tptp4x.check/2`, which validates
  # its own opts. Keeping this schema in step with that one is the reason
  # both modules enumerate their keys — see `lint/tptp4x.ex`.
  @opts_schema NimbleOptions.new!(
                 backends: [type: {:list, {:in, [:local, :tptp4x]}}],
                 url: [type: :string],
                 tptp4x_system: [type: :string],
                 tptp4x_time_limit_sec: [type: :non_neg_integer],
                 request_timeout_ms: [type: :non_neg_integer]
               )

  @doc """
  Runs the enabled backends against `problem` and returns a merged
  `Report`.

  ## Options

    * `:backends` — a list of `t:backend/0` atoms. Defaults to
      `#{inspect(@default_backends)}`;
    * any option accepted by the chosen backends (e.g. `:url`,
      `:tptp4x_system`) — forwarded verbatim.

  When both backends run and the local pass reports any `:error`
  diagnostic, the remote pass is skipped: the user will fix the obvious
  issue first, and a failing TPTP4X result on top of a local error adds
  noise without new information. Warnings do not suppress the remote
  pass.
  """
  @spec analyze(String.t(), keyword()) :: Report.t()
  def analyze(problem, opts \\ []) when is_binary(problem) do
    NimbleOptions.validate!(opts, @opts_schema)
    backends = Keyword.get(opts, :backends, @default_backends)
    %Report{diagnostics: local_diags, symbols: symbols} = run_local(backends, problem)
    remote_diags = run_remote(backends, problem, opts, local_diags)

    diagnostics =
      (local_diags ++ remote_diags)
      |> Enum.sort_by(&{&1.line, &1.column, severity_rank(&1.severity)})

    %Report{diagnostics: diagnostics, symbols: symbols}
  end

  defp run_local(backends, problem) do
    if :local in backends,
      do: AtpClient.Lint.Local.analyze(problem),
      else: %Report{diagnostics: [], symbols: []}
  end

  # Network issues are surfaced via a separate channel so they don't
  # pollute the editor markers — the Smart Cell can log them or surface
  # them as a non-marker status instead.
  #
  # `:backends` is our own key and is not part of `Tptp4x.check/2`'s
  # schema, so strip it before forwarding — otherwise the callee's
  # NimbleOptions validator would reject it.
  defp run_remote(backends, problem, opts, local_diags) do
    if :tptp4x in backends and not has_errors?(local_diags) do
      case AtpClient.Lint.Tptp4x.check(problem, Keyword.delete(opts, :backends)) do
        {:ok, diags} -> diags
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  @doc """
  Convenience wrapper that returns just the diagnostics list — useful
  for callers that don't care about symbol extraction.
  """
  @spec check(String.t(), keyword()) :: {:ok, [Diagnostic.t()]}
  def check(problem, opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)
    %Report{diagnostics: diags} = analyze(problem, opts)
    {:ok, diags}
  end

  defp has_errors?(diags), do: Enum.any?(diags, &(&1.severity == :error))

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 2
  defp severity_rank(:hint), do: 3
end
