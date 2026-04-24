defmodule AtpClient.Lint do
  @moduledoc """
  Syntax and type diagnostics for TPTP input, aggregated across one or
  more backends.

  Two backends ship with this module:

    * `AtpClient.Lint.Local` — a pure-Elixir structural checker that runs
      in-process, catches common typos (unknown role, missing dot,
      mismatched brackets) and extracts type declarations for hover and
      completion data.
    * `AtpClient.Lint.Tptp4x` — delegates to TPTP4x on the configured
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
  issue first, and a failing TPTP4x result on top of a local error adds
  noise without new information. Warnings do not suppress the remote
  pass.
  """
  @spec analyze(String.t(), keyword()) :: Report.t()
  def analyze(problem, opts \\ []) when is_binary(problem) do
    backends = Keyword.get(opts, :backends, @default_backends)

    %Report{diagnostics: local_diags, symbols: symbols} =
      if :local in backends do
        AtpClient.Lint.Local.analyze(problem)
      else
        %Report{diagnostics: [], symbols: []}
      end

    remote_diags =
      if :tptp4x in backends and not has_errors?(local_diags) do
        case AtpClient.Lint.Tptp4x.check(problem, opts) do
          {:ok, diags} -> diags
          # Network issues are surfaced via a separate channel so they
          # don't pollute the editor markers — the Smart Cell can log
          # them or surface them as a non-marker status instead.
          {:error, _reason} -> []
        end
      else
        []
      end

    %Report{
      diagnostics:
        (local_diags ++ remote_diags)
        |> Enum.sort_by(&{&1.line, &1.column, severity_rank(&1.severity)}),
      symbols: symbols
    }
  end

  @doc """
  Convenience wrapper that returns just the diagnostics list — useful
  for callers that don't care about symbol extraction.
  """
  @spec check(String.t(), keyword()) :: {:ok, [Diagnostic.t()]}
  def check(problem, opts \\ []) do
    %Report{diagnostics: diags} = analyze(problem, opts)
    {:ok, diags}
  end

  defp has_errors?(diags), do: Enum.any?(diags, &(&1.severity == :error))

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 2
  defp severity_rank(:hint), do: 3
  defp severity_rank(_), do: 4
end
