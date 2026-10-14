defmodule AtpClient.Verdict do
  @moduledoc """
  Reads a system's output into an `AtpClient.Result`.

  Four readings run in order, and the first that finds something decides:

    1. The SZS status line, through `Tptp.Szs.status/1`: the last status line in the
       output outside its delimited output blocks, with its value looked up in
       `Tptp.Szs.Ontology`. A status line inside a block is part of the data the
       block carries — ECNF prints `SZS status Unknown` inside its `ListOfCNF` —
       and not the system's verdict. A word the ontology does not define is
       reported as `{:error, {:unknown_szs_status, word}}`, not converted to an
       atom, unless the system's own `Solved` patterns (step 3) read the output. A
       value from the data ontology on a status line, such as `Proof`, is
       `{:error, {:not_a_status, value}}`.
    2. The SystemOnTPTP summary line, `% RESULT: <problem> - <system> says <Value>`,
       which SystemOnTPTP prints for every system it ran and which carries the same
       vocabulary; failing that, the first `<system> says <Value>` anywhere.
    3. The system's own `Solved` patterns from its SystemOnTPTP record, when the
       caller passes them as `:solved` (`t:AtpClient.System.t/0`'s `solved`):
       AGMV's record maps `VerifiedGood` to `SZS status Verified`, Dedukti's to
       `successfully checked`. A pattern is text and is found where it occurs and
       is not followed by a further letter, digit or underscore, so `SZS status
       Verified` does not occur in `SZS status VerifiedBad`; where several occur
       the longest wins. `:gave_up` takes a list of the record's `GaveUp`
       patterns, read the same way.
    4. Prover-specific messages from systems that do not (always) print an SZS
       line — Alt-Ergo, E, LEO-II, SPASS, Vampire, Waldmeister. The table is
       `patterns/0`. Each entry maps to the most faithful SZS value the message
       alone supports; where a verdict is sound only under flags the reader cannot
       see, such as SPASS saturating under `-SOS`, the entry is the conservative
       `:gave_up`. Only the messages of the system that ran are read
       (`patterns/1`): Alt-Ergo's `: Unknown` is not a verdict in E's output.
       The table is for systems the SystemOnTPTP record does not cover, and is
       expected to shrink.

  Output none of the four reads is `{:error, {:unrecognized_output, output}}`.

  Isabelle does not print SZS lines; `AtpClient.Isabelle.Verdict` reads its
  messages.
  """

  alias AtpClient.Result
  alias Tptp.Szs
  alias Tptp.Szs.Ontology

  @typedoc """
  Why no result could be read from the output.

    * `{:unknown_szs_status, word}` — a status line names a value the ontology does
      not define.
    * `{:not_a_status, value}` — a status line names a data value.
    * `{:unrecognized_output, output}` — no status line and no known pattern.
    * `:internal_error` — a pattern that identifies a crash of the system rather
      than a verdict.
  """
  @type failure ::
          {:unknown_szs_status, binary()}
          | {:not_a_status, Ontology.t()}
          | {:unrecognized_output, binary()}
          | :internal_error

  # Each group belongs to the systems that print its messages: their
  # SystemOnTPTP names, and the executables LocalExec runs them as. A message
  # such as Alt-Ergo's `: Unknown` is ordinary text in another system's output
  # (SystemOnTPTP's `ERROR: Unknown procedure`), so a group is read only for its
  # own systems. `test/atp_client/verdict_test.exs` checks every name against the
  # shipped snapshot.
  @patterns [
    # Alt-Ergo (Why3-wrapped: ": Valid", ": Timeout"; native: "I don't know")
    %{
      names: ["Alt-Ergo"],
      binaries: ["alt-ergo"],
      patterns: [
        {": Valid", {:ok, :theorem}},
        {": Timeout", {:ok, :timeout}},
        {": Unknown", {:ok, :unknown}},
        {"I don't know", {:ok, :gave_up}}
      ]
    },
    # E. E-Darwin is not E.
    %{
      names: ["E", "E-SAT"],
      binaries: ["eprover", "eprover-ho"],
      patterns: [
        {"Failure: Resource limit exceeded (time)", {:ok, :timeout}},
        {"Failure: Resource limit exceeded (memory)", {:ok, :memory_out}},
        {"time limit exceeded", {:ok, :timeout}}
      ]
    },
    %{
      names: ["LEO-II"],
      binaries: ["leo"],
      patterns: [
        {"CPU time limit exceeded, terminating", {:ok, :timeout}},
        {"No.of.Axioms", {:ok, :gave_up}}
      ]
    },
    # SPASS. "Completion found" is a saturation, which witnesses
    # (counter)satisfiability only under a refutationally complete strategy the
    # reader cannot verify. Input rejections are the system's own InputError
    # verdict; "Please report this error" is a crash.
    %{
      names: ["SPASS", "SPASS+T"],
      binaries: ["spass"],
      patterns: [
        {"SPASS beiseite: Completion found", {:ok, :gave_up}},
        {"SPASS beiseite: Ran out of time", {:ok, :timeout}},
        {"SPASS beiseite: Maximal number of loops exceeded", {:ok, :resource_out}},
        {"No formulae and clauses found in input file", {:ok, :input_error}},
        {"Undefined symbol", {:ok, :input_error}},
        {"Free Variable", {:ok, :input_error}},
        {"Please report this error", {:error, :internal_error}}
      ]
    },
    # Vampire. Saturation without SZS mode does not say whether a conjecture was
    # present, so it is :gave_up; in SZS mode Vampire prints the line itself.
    %{
      names: [
        "Vampire",
        "Vampire-FMo",
        "Vampire-LIT",
        "Vampire-LP",
        "Vampire-SAT",
        "Vampire-SATLIT"
      ],
      binaries: ["vampire"],
      patterns: [
        {"UNPROVABLE", {:ok, :gave_up}},
        {"CANNOT PROVE", {:ok, :gave_up}},
        {"Satisfiability detected", {:ok, :gave_up}},
        {"Termination reason: Satisfiable", {:ok, :gave_up}},
        {"Time limit reached!", {:ok, :timeout}},
        {"Aborted by signal SIGINT", {:ok, :forced}}
      ]
    },
    # Waldmeister. "Unexpected end of file" is what non-UEQ input produces.
    %{
      names: ["Waldmeister"],
      binaries: ["waldmeister"],
      patterns: [
        {"Too many function symbols", {:ok, :resource_out}},
        {"****  Unexpected end of file.", {:ok, :inappropriate}},
        {"Unrecoverable Segmentation Fault", {:error, :internal_error}}
      ]
    }
  ]

  @says ~r/\bsays\s+([A-Z][A-Za-z]{2,39})\b/
  @result_says ~r/^% RESULT: .*\bsays\s+([A-Z][A-Za-z]{2,39})\b/m

  # From a start marker line to the end marker line that closes it; the status
  # reading looks at the output with these removed. A start that is never closed
  # is left in place, as `Tptp.Szs.blocks/2` leaves it out.
  @block ~r/^[^\n]*SZS output start\b[^\n]*$.*?^[^\n]*SZS output end\b[^\n]*$/ms

  # Options read by `interpret/3`; everything else in `fields` goes on the result.
  @options [:prefix, :solved, :gave_up, :system_name]

  @doc """
  Reads `output` from `backend` into a result.

  `fields` are put on the result as given: `:system` names the system that ran.
  Three of them are options and are not put on the result:

    * `:prefix` — a pattern or list of patterns removed from every line of a block
      body, passed to `Tptp.Szs.blocks/2`; StarExec passes
      `[Tptp.Szs.prefix(:starexec)]`.
    * `:solved` — the system's `Solved` patterns, `%{value => pattern}`.
    * `:gave_up` — the system's `GaveUp` patterns, `[pattern]`.
    * `:system_name` — the SystemOnTPTP name whose messages (`patterns/1`) are
      read, where `:system` does not name it: StarExec's `:system` is a
      configuration id, LocalExec's a binary that may be a wrapper script.
      Defaults to `:system`.

  For example:

      iex> {:ok, result} = AtpClient.Verdict.interpret("# SZS status Theorem\\n", AtpClient.LocalExec, system: "eprover")
      iex> {result.status, result.evidence, result.system}
      {:theorem, :szs, "eprover"}

      iex> AtpClient.Verdict.interpret("% SZS status Nonsense for x", AtpClient.LocalExec)
      {:error, {:unknown_szs_status, "Nonsense"}}

      iex> output = "% SZS status Verified for x"
      iex> {:ok, result} = AtpClient.Verdict.interpret(output, AtpClient.LocalExec, solved: %{verified_good: "SZS status Verified", verified_bad: "SZS status VerifiedBad"})
      iex> {result.status, result.evidence}
      {:verified_good, {:system_info, "VerifiedGood"}}

      iex> {:ok, result} = AtpClient.Verdict.interpret("SPASS beiseite: Completion found", AtpClient.LocalExec)
      iex> {result.status, result.evidence}
      {:gave_up, {:pattern, "SPASS beiseite: Completion found"}}

      iex> AtpClient.Verdict.interpret("ERROR: Unknown procedure", AtpClient.SystemOnTptp, system: "E---3.5.1")
      {:error, {:unrecognized_output, "ERROR: Unknown procedure"}}

      iex> AtpClient.Verdict.interpret("nothing to see", AtpClient.LocalExec)
      {:error, {:unrecognized_output, "nothing to see"}}
  """
  @spec interpret(binary(), module(), keyword()) :: {:ok, Result.t()} | {:error, failure()}
  def interpret(output, backend, fields \\ []) when is_binary(output) and is_atom(backend) do
    {options, fields} = Keyword.split(fields, @options)

    with :none <- szs(output, backend, fields, options),
         :none <- says(output, backend, fields, options),
         :none <- solved(output, backend, fields, options),
         :none <- pattern(output, backend, fields, options) do
      {:error, {:unrecognized_output, output}}
    end
  end

  @typedoc "A message and the result it stands for."
  @type pattern :: {binary(), {:ok, Ontology.t()} | {:error, :internal_error}}

  @typedoc """
  The messages of one family of systems: the SystemOnTPTP `names` it is read
  for, and the `binaries` LocalExec runs those systems as.
  """
  @type group :: %{names: [String.t()], binaries: [String.t()], patterns: [pattern()]}

  @doc """
  The prover-specific messages read when no SZS line is present, grouped by the
  systems that print them.
  """
  @spec patterns() :: [group()]
  def patterns, do: @patterns

  @doc """
  The prover-specific messages read for `system`.

  `system` is a SystemOnTPTP identifier or name (`"E---3.5.1"`, `"Vampire-SAT"`)
  or an executable as LocalExec runs it (`"eprover"`, `"/opt/bin/vampire"`), and
  gets its own group's messages: a name compares exactly, an executable by its
  base name and in any case. A system no group claims gets none. `nil`, a
  system not known at all, gets every group's.

      iex> AtpClient.Verdict.patterns("Alt-Ergo---2.6.2") |> Enum.map(&elem(&1, 0)) |> Enum.member?(": Unknown")
      true

      iex> AtpClient.Verdict.patterns("E---3.5.1") |> Enum.map(&elem(&1, 0)) |> Enum.member?(": Unknown")
      false

      iex> AtpClient.Verdict.patterns("E-Darwin---1.5")
      []
  """
  @spec patterns(String.t() | nil) :: [pattern()]
  def patterns(nil), do: Enum.flat_map(@patterns, & &1.patterns)

  def patterns(system) when is_binary(system) do
    name = system |> String.split("---", parts: 2) |> hd()
    binary = name |> Path.basename() |> String.downcase()

    Enum.flat_map(@patterns, fn group ->
      if name in group.names or binary in group.binaries, do: group.patterns, else: []
    end)
  end

  @spec szs(binary(), module(), keyword(), keyword()) ::
          {:ok, Result.t()} | {:error, failure()} | :none
  defp szs(output, backend, fields, options) do
    case output |> outside_blocks() |> Szs.status() do
      {:ok, value, problem, comment} ->
        status(
          value,
          :szs,
          output,
          backend,
          [problem: problem, comment: comment] ++ fields,
          options
        )

      {:error, word, _problem, _comment} ->
        case solved(output, backend, fields, options) do
          :none -> {:error, {:unknown_szs_status, word}}
          found -> found
        end

      :none ->
        :none
    end
  end

  @spec outside_blocks(binary()) :: binary()
  defp outside_blocks(output), do: Regex.replace(@block, output, "")

  @spec says(binary(), module(), keyword(), keyword()) ::
          {:ok, Result.t()} | {:error, failure()} | :none
  defp says(output, backend, fields, options) do
    matched =
      case Regex.scan(@result_says, output) do
        [] -> Regex.run(@says, output)
        lines -> List.last(lines)
      end

    case matched do
      [line, word] ->
        case Ontology.from_string(word) do
          {:ok, value} ->
            status(value, {:pattern, String.trim(line)}, output, backend, fields, options)

          :error ->
            {:error, {:unknown_szs_status, word}}
        end

      nil ->
        :none
    end
  end

  @spec solved(binary(), module(), keyword(), keyword()) :: {:ok, Result.t()} | :none
  defp solved(output, backend, fields, options) do
    solved = for {value, pattern} <- Keyword.get(options, :solved, %{}), do: {value, pattern}
    gave_up = for pattern <- Keyword.get(options, :gave_up, []), do: {:gave_up, pattern}

    (solved ++ gave_up)
    |> Enum.filter(fn {_value, pattern} -> occurs?(output, pattern) end)
    |> Enum.max_by(fn {_value, pattern} -> byte_size(pattern) end, fn -> nil end)
    |> case do
      {value, _pattern} ->
        result(value, {:system_info, Ontology.name(value)}, output, backend, fields, options)

      nil ->
        :none
    end
  end

  @spec occurs?(binary(), binary()) :: boolean()
  defp occurs?(_output, ""), do: false

  defp occurs?(output, pattern) do
    String.contains?(output, pattern) and
      Regex.match?(Regex.compile!(Regex.escape(pattern) <> "(?![A-Za-z0-9_])"), output)
  end

  @spec pattern(binary(), module(), keyword(), keyword()) ::
          {:ok, Result.t()} | {:error, failure()} | :none
  defp pattern(output, backend, fields, options) do
    patterns = options |> Keyword.get(:system_name, fields[:system]) |> patterns()

    case Enum.find(patterns, fn {text, _verdict} -> String.contains?(output, text) end) do
      {text, {:ok, value}} -> result(value, {:pattern, text}, output, backend, fields, options)
      {_text, {:error, _reason} = error} -> error
      nil -> :none
    end
  end

  @spec status(Ontology.t(), Result.evidence(), binary(), module(), keyword(), keyword()) ::
          {:ok, Result.t()} | {:error, failure()}
  defp status(value, evidence, output, backend, fields, options) do
    if Ontology.success?(value) or Ontology.no_success?(value) do
      result(value, evidence, output, backend, fields, options)
    else
      {:error, {:not_a_status, value}}
    end
  end

  @spec result(Ontology.t(), Result.evidence(), binary(), module(), keyword(), keyword()) ::
          {:ok, Result.t()}
  defp result(value, evidence, output, backend, fields, options) do
    base = %Result{
      status: value,
      evidence: evidence,
      output: output,
      backend: backend,
      blocks: Szs.blocks(output, Keyword.take(options, [:prefix]))
    }

    {:ok, struct!(base, fields)}
  end
end
