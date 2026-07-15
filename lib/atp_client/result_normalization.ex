defmodule AtpClient.ResultNormalization do
  @moduledoc """
  Interprets output from various provers into SZS-faithful atoms.

  Each backend returns the same `t:atp_result/0` shape: `{:ok, status}` where
  `status` is the SZS Ontology verdict downcased to an Elixir atom (e.g.
  `:theorem`, `:unsatisfiable`, `:counter_satisfiable`, `:satisfiable`,
  `:gave_up`, `:timeout`, …), or `{:error, reason}` when the call could not
  produce any SZS verdict (network failure, malformed prover output, missing
  binary). The distinction between e.g. `:theorem` ("conjecture follows from
  the axioms") and `:unsatisfiable` ("the clause set has no model") is
  preserved so callers do not lose information across backends — see
  https://tptp.org/Seminars/SZSOntologies/Summary.html for the full ontology.

  TPTP-oriented prover outputs (SystemOnTPTP, StarExec, LocalExec) are
  classified by `interpret_result/1`; Isabelle `use_theories` payloads by
  `interpret_isabelle_result/1` and `per_lemma_results/3`.
  """

  @typedoc "Standardized format for ATP outputs."
  @type atp_result :: {:ok, szs_status()} | {:error, failure_t()}

  @typedoc """
  SZS Ontology status atoms surfaced to callers. The Success/NoSuccess split
  mirrors the SZS hierarchy. The unions below enumerate the atoms the
  classifier maps explicitly — i.e. the SZS verdicts a sledgehammer-targeted
  prover (or a contemporary TPTP-compliant system) is likely to emit. A
  permissive fallback in `interpret_result/1` also converts any unrecognised
  `% SZS status <CamelCase>` line to its snake-case atom (`Tautology` →
  `:tautology`, `EquivalentTheorem` → `:equivalent_theorem`), so the runtime
  shape is `atom()`; the typespec lists the well-known names for callers
  that pattern-match.

    * Success — a definite verdict: `:theorem`, `:unsatisfiable`,
      `:satisfiable`, `:counter_satisfiable`, `:contradictory_axioms`,
      `:equivalent`, `:counter_equivalent`, `:counter_theorem`,
      `:equivalent_counter_theorem`, `:equi_satisfiable`,
      `:tautology`, `:tautologous_conclusion`, `:weaker_conclusion`,
      `:no_consequence`.
    * NoSuccess — the prover finished without classifying the input as
      Success: `:gave_up`, `:unknown`, `:incomplete`, `:timeout`,
      `:resource_out`, `:memory_out`, `:forced`, `:user`,
      `:inappropriate`, `:error`, `:input_error`.
  """
  @type szs_status :: szs_success() | szs_no_success() | atom()

  @typedoc "SZS Success statuses recognised explicitly by `interpret_result/1`."
  @type szs_success ::
          :theorem
          | :unsatisfiable
          | :satisfiable
          | :counter_satisfiable
          | :contradictory_axioms
          | :equivalent
          | :counter_equivalent
          | :counter_theorem
          | :equivalent_counter_theorem
          | :equi_satisfiable
          | :tautology
          | :tautologous_conclusion
          | :weaker_conclusion
          | :no_consequence

  @typedoc "SZS NoSuccess statuses recognised explicitly by `interpret_result/1`."
  @type szs_no_success ::
          :gave_up
          | :unknown
          | :incomplete
          | :timeout
          | :resource_out
          | :memory_out
          | :forced
          | :user
          | :inappropriate
          | :error
          | :input_error

  @typedoc """
  Backend errors that prevented any SZS verdict from being produced.

  These are not SZS statuses — they describe problems on the path between the
  caller and the prover (no executable, output the classifier could not parse,
  prover crash with no SZS line, malformed input rejected before classification).
  """
  @type failure_t ::
          :internal_error
          | :input_error
          | {:prover_not_found, String.t()}
          | {:unrecognized_output, String.t()}

  # Matched via word-boundary regex extraction in `szs_line_match/1`, so
  # entry order does not affect precedence — only the set of names matters.
  @known_szs_results [
    # Success — counter-family before plain forms.
    {"ContradictoryAxioms", {:ok, :contradictory_axioms}},
    {"EquivalentCounterTheorem", {:ok, :equivalent_counter_theorem}},
    {"CounterEquivalent", {:ok, :counter_equivalent}},
    {"CounterTheorem", {:ok, :counter_theorem}},
    {"CounterSatisfiable", {:ok, :counter_satisfiable}},
    {"TautologousConclusion", {:ok, :tautologous_conclusion}},
    {"WeakerConclusion", {:ok, :weaker_conclusion}},
    {"EquiSatisfiable", {:ok, :equi_satisfiable}},
    {"Equivalent", {:ok, :equivalent}},
    {"NoConsequence", {:ok, :no_consequence}},
    {"Tautology", {:ok, :tautology}},
    {"Theorem", {:ok, :theorem}},
    {"Unsatisfiable", {:ok, :unsatisfiable}},
    {"Satisfiable", {:ok, :satisfiable}},

    # NoSuccess — InputError before Error (sub-status of Error).
    {"InputError", {:ok, :input_error}},
    {"Error", {:ok, :error}},
    {"GaveUp", {:ok, :gave_up}},
    {"Unknown", {:ok, :unknown}},
    {"Incomplete", {:ok, :incomplete}},
    {"Timeout", {:ok, :timeout}},
    {"ResourceOut", {:ok, :resource_out}},
    {"MemoryOut", {:ok, :memory_out}},
    {"Forced", {:ok, :forced}},
    {"User", {:ok, :user}},
    {"Inappropriate", {:ok, :inappropriate}}
  ]

  # Prover output snippets emitted by solvers that do not (always) print an
  # SZS status line. Each pattern is mapped to the most faithful SZS atom the
  # classifier can determine from the output alone. Where a verdict is only
  # sound under specific prover strategy flags that the classifier cannot see
  # (e.g. SPASS saturation under `-SOS`), the conservative `:gave_up` is
  # returned; callers who control the prover's flags can use `raw: true` and
  # interpret the raw output themselves.
  @prover_specific_results [
    # Alt-Ergo (Why3-wrapped: ": Valid", ": Timeout"; native: "I don't know")
    {": Valid", {:ok, :theorem}},
    {": Timeout", {:ok, :timeout}},
    {": Unknown", {:ok, :unknown}},
    {"I don't know", {:ok, :gave_up}},

    # E
    {"Failure: Resource limit exceeded (time)", {:ok, :timeout}},
    {"Failure: Resource limit exceeded (memory)", {:ok, :memory_out}},
    {"time limit exceeded", {:ok, :timeout}},

    # LEO-II
    {"CPU time limit exceeded, terminating", {:ok, :timeout}},
    {"No.of.Axioms", {:ok, :gave_up}},

    # SPASS — input-error patterns are prover verdicts (SZS InputError),
    # so they go in the {:ok, _} channel; "Please report this error" is a
    # SPASS internal failure that we cannot trust to be a verdict.
    # "Completion found" means the clause set was saturated, which is only a
    # sound (counter)satisfiability witness under a refutationally complete
    # strategy; since the classifier cannot verify which strategy was used,
    # the conservative :gave_up is returned.
    {"SPASS beiseite: Completion found", {:ok, :gave_up}},
    {"SPASS beiseite: Ran out of time", {:ok, :timeout}},
    {"SPASS beiseite: Maximal number of loops exceeded", {:ok, :resource_out}},
    {"No formulae and clauses found in input file", {:ok, :input_error}},
    {"Undefined symbol", {:ok, :input_error}},
    {"Free Variable", {:ok, :input_error}},
    {"Please report this error", {:error, :internal_error}},

    # Vampire — saturation patterns are conservative :gave_up because the
    # classifier cannot tell whether a conjecture was present; in SZS mode
    # Vampire emits the correct status line itself (handled by layer 1).
    {"UNPROVABLE", {:ok, :gave_up}},
    {"CANNOT PROVE", {:ok, :gave_up}},
    {"Satisfiability detected", {:ok, :gave_up}},
    {"Termination reason: Satisfiable", {:ok, :gave_up}},
    {"Time limit reached!", {:ok, :timeout}},
    {"Aborted by signal SIGINT", {:ok, :forced}},

    # Waldmeister — same channel split: input rejection is a verdict,
    # a SegFault is not. "Unexpected end of file" typically means non-UEQ
    # input handed to a UEQ-only prover → SZS Inappropriate.
    {"Too many function symbols", {:ok, :resource_out}},
    {"****  Unexpected end of file.", {:ok, :inappropriate}},
    {"Unrecoverable Segmentation Fault", {:error, :internal_error}}
  ]

  @doc """
  Interprets the output of provers that follow the SZS ontology (including
  those available on SystemOnTPTP) into the standardized representation.

  Three layers run in order:

    1. The explicit SZS table (`@known_szs_results`) recognises every status
       in `t:szs_success/0` and `t:szs_no_success/0` from a
       `"SZS status <Name>"` or `" says <Name>"` substring. An explicit SZS
       line always wins over any prover-specific pattern.
    2. A permissive fallback converts any remaining
       `"SZS status <CamelCase>"` (or `" says <CamelCase>"`) line to its
       snake-case atom, so SZS additions like `EquivalentTheorem` become
       `{:ok, :equivalent_theorem}` without a code change.
    3. Prover-specific patterns for solvers that do not (always) emit an SZS
       status line — Alt-Ergo, E, LEO-II, SPASS, Vampire, Waldmeister.
       Mirrors `sledgehammer_atp_systems.ML` (seL4/isabelle mirror, verified
       2026-07-14). iProver always emits a proper SZS status line and
       classifies via layer 1.

  Output that none of the three layers matches comes back as
  `{:error, {:unrecognized_output, res_str}}`.
  """
  @spec interpret_result(String.t()) :: atp_result()
  def interpret_result(res_str) do
    szs_line_match(res_str) || prover_specific_match(res_str) ||
      {:error, {:unrecognized_output, res_str}}
  end

  defp prover_specific_match(res_str) do
    Enum.find_value(@prover_specific_results, fn {pattern, result} ->
      if String.contains?(res_str, pattern), do: result
    end)
  end

  # SZS status / says lines are extracted by regex with a word boundary
  # after the captured name, so e.g. "EquivalentTheorem" does not collapse
  # onto the "Equivalent" entry. Unknown names fall through to a
  # CamelCase → snake_case atom (permissive pass-through), bounded in
  # length to keep the atom table safe against pathological input.
  @szs_line_pattern ~r/(?:SZS status |\bsays )([A-Z][A-Za-z]{2,39})\b/
  defp szs_line_match(res_str) do
    case Regex.run(@szs_line_pattern, res_str) do
      [_, name] ->
        Map.get(known_szs_map(), name) ||
          {:ok, String.to_atom(Macro.underscore(name))}

      _ ->
        nil
    end
  end

  defp known_szs_map do
    Map.new(@known_szs_results, fn {name, result} -> {name, result} end)
  end

  @doc """
  Interprets the `result` payload of a finished `use_theories` task — the map
  returned in `%IsabelleClient.Task{status: :finished, result: ...}`, with
  top-level keys `"ok"`, `"errors"`, `"nodes"`, etc.

  Classification is driven by the messages Isabelle emits, not by whether the
  task finished without errors. Each message is classified individually to
  avoid false positives from cross-message substring matches. See
  `per_lemma_results/3` for the verdict precedence; this function applies the
  same logic treating all messages as a single bucket.

  Always returns `{:ok, szs_status()}` — no payload shape currently causes the
  classifier to bail out with `{:error, _}`. Callers that also handle
  transport / session failures should catch those at the `AtpClient.Isabelle`
  layer instead. Note: payloads with `"ok": false` (proof errors) are still
  handled here — the proof-method failure veto prevents a theorem echo from
  being mistaken for a proof success.
  """
  @spec interpret_isabelle_result(map()) :: {:ok, szs_status()}
  def interpret_isabelle_result(payload) when is_map(payload) do
    messages = extract_messages(payload)
    {:ok, classify_lemma_bucket(messages)}
  end

  defp theorem_at_start?(text),
    do: String.starts_with?(text, "theorem ") or String.starts_with?(text, "theorem:")

  defp nitpick_found?(text, what),
    do: String.contains?(text, "Nitpick found a") and String.contains?(text, what)

  defp quickcheck_found?(text, what),
    do: String.contains?(text, "Quickcheck found a") and String.contains?(text, what)

  defp found_a_proof?(text), do: String.contains?(text, "found a proof")
  defp found_proof?(text), do: String.contains?(text, "Found proof")
  defp out_of_memory?(text), do: String.contains?(text, "Out of memory")

  defp gave_up?(text),
    do: String.contains?(text, "Nitpick found no") or String.contains?(text, "No proof found")

  defp timeout?(text),
    do: String.contains?(text, "timed out") or String.contains?(text, "TIMEOUT")

  @doc """
  Concatenates all `"message"` strings from a `use_theories` payload (the
  `result` field of a finished `%IsabelleClient.Task{}`) into a single
  newline-separated string.

  Walks all nodes in the payload, not just the first — useful when a theory
  transitively imports others and the server reports messages against multiple
  nodes.
  """
  @spec extract_isabelle_text(map()) :: String.t()
  def extract_isabelle_text(payload) when is_map(payload), do: extract_text(payload)

  @typedoc """
  Specification for one lemma in a generated theory body, as computed
  internally by `AtpClient.Isabelle.prove_lemmas/4` / `prove_tptp/3`.

    * `name` — lemma name as written in the body (the same string the
      classifier surfaces in `t:lemma_result/0`).
    * `range` — body-line range (inclusive) the lemma covers, from its
      `lemma <name>:` line through the line before the next `lemma` (or
      the end of the body). Used by `per_lemma_results/3` to bucket
      Isabelle messages without relying on the exact `pos.line` of each
      message, which is noisy for sledgehammer / nitpick output.
  """
  @type lemma_spec :: %{name: String.t(), range: Range.t()}

  @typedoc """
  Per-lemma result returned by `per_lemma_results/3`.

  Carries the lemma name from the input body (not parsed out of Isabelle
  messages, which omit it for `oops`-based diagnostic methods) and the
  classified outcome. The on-disk line number is intentionally not
  exposed: it refers to the generated theory file, not the caller's TPTP
  source, so it would mislead more often than it would help.
  """
  @type lemma_result :: %{name: String.t() | nil, result: atp_result()}

  @doc """
  Classifies a finished `use_theories` payload into one entry per lemma,
  in the order given by `lemma_specs`.

  Messages from each lemma's body-line range are bucketed and scanned
  one-at-a-time — never across the concatenated text of a bucket. The
  cross-message scan that earlier versions of this function used produced
  false `:counter_satisfiable` verdicts when one message read `Nitpick
  found a model` and another read `Nitpick found no counterexample` (the
  `"Nitpick found a" + "counterexample"` substring test fires across the
  two), and false `:theorem` verdicts when `by auto` failed on a False
  goal (Isabelle still echoes `theorem name: <goal>` at the `by` position
  next to the `Failed to finish proof` error).

  ## Options

    * `:file` — keep only messages whose `pos.file` ends with the given
      suffix (typically `"/<theory_name>.thy"`). Messages from the bundled
      `TPTP.thy` and from transitively imported theories are dropped.
      Defaults to no filter.
    * `:line_offset` — number to subtract from each Isabelle-reported
      `pos.line` before comparing against `lemma_spec.range`. Auto-wrap
      adds one line (`theory <name> imports … begin`) to the on-disk
      file, so callers that pass a body without the header set this to
      `1`. Defaults to `0`.

  ## Verdict precedence

  Within a lemma bucket, signals collected per-message are reconciled in
  this order (each step short-circuits):

    1. `:counter_satisfiable` (Nitpick / Quickcheck counter-example) —
       disproves the goal; dominates any concurrent proof attempt.
    2. `:theorem` from a sledgehammer / metis `"found a proof"` line.
    3. `:satisfiable` (Nitpick / Quickcheck model).
    4. Proof-method failure veto — an `error`-kind message containing
       `"Failed to finish proof"` cancels a `theorem name:` verdict from
       the same bucket.
    5. `:theorem` from a `theorem name:` completion notification.
    6. `:timeout`, `:memory_out`, then `:gave_up`.

  Lemmas whose bucket is empty come back as `{:ok, :gave_up}`.
  """
  @spec per_lemma_results(map(), [lemma_spec()], keyword()) :: [lemma_result()]
  def per_lemma_results(payload, lemma_specs, opts \\ []) when is_map(payload) do
    file_suffix = Keyword.get(opts, :file)
    line_offset = Keyword.get(opts, :line_offset, 0)

    messages =
      payload
      |> extract_messages()
      |> filter_by_file(file_suffix)

    Enum.map(lemma_specs, fn %{name: name, range: range} ->
      in_range = Enum.filter(messages, &message_in_range?(&1, range, line_offset))
      %{name: name, result: {:ok, classify_lemma_bucket(in_range)}}
    end)
  end

  defp filter_by_file(messages, nil), do: messages

  defp filter_by_file(messages, suffix) when is_binary(suffix) do
    Enum.filter(messages, fn msg ->
      case get_in(msg, ["pos", "file"]) do
        file when is_binary(file) -> String.ends_with?(file, suffix)
        _ -> false
      end
    end)
  end

  defp message_in_range?(msg, range, line_offset) do
    case get_in(msg, ["pos", "line"]) do
      line when is_integer(line) -> line - line_offset in range
      _ -> false
    end
  end

  defp classify_lemma_bucket(messages) do
    verdicts =
      messages
      |> Enum.map(&classify_lemma_message/1)
      |> Enum.reject(&is_nil/1)

    cond do
      :counter_satisfiable in verdicts -> :counter_satisfiable
      :theorem_proof in verdicts -> :theorem
      :satisfiable in verdicts -> :satisfiable
      proof_method_failure?(messages) -> :gave_up
      :theorem_completion in verdicts -> :theorem
      :timeout in verdicts -> :timeout
      :memory_out in verdicts -> :memory_out
      :gave_up_hint in verdicts -> :gave_up
      any_error?(messages) -> :gave_up
      true -> :gave_up
    end
  end

  defp classify_lemma_message(msg) do
    text = Map.get(msg, "message", "")

    cond do
      nitpick_found?(text, "counterexample") -> :counter_satisfiable
      quickcheck_found?(text, "counterexample") -> :counter_satisfiable
      nitpick_found?(text, "model") -> :satisfiable
      quickcheck_found?(text, "model") -> :satisfiable
      found_a_proof?(text) -> :theorem_proof
      found_proof?(text) -> :theorem_proof
      timeout?(text) -> :timeout
      out_of_memory?(text) -> :memory_out
      gave_up?(text) -> :gave_up_hint
      theorem_at_start?(text) -> :theorem_completion
      true -> nil
    end
  end

  # Isabelle echoes `theorem name: <goal>` at the `by` position even for a
  # tactic that fails to discharge the goal — the message is just the
  # current proof state, not a success notification. The accompanying error
  # message tells us the goal stayed open.
  defp proof_method_failure?(messages) do
    Enum.any?(messages, fn msg ->
      Map.get(msg, "kind") == "error" and
        msg
        |> Map.get("message", "")
        |> then(
          &(String.contains?(&1, "Failed to finish proof") or
              String.contains?(&1, "Failed to apply initial proof method"))
        )
    end)
  end

  defp any_error?(messages),
    do: Enum.any?(messages, &(Map.get(&1, "kind") == "error"))

  defp extract_text(payload) do
    payload
    |> extract_messages()
    |> Enum.map_join("\n", fn msg -> Map.get(msg, "message", "") end)
  end

  defp extract_messages(%{"nodes" => nodes}) when is_list(nodes) do
    Enum.flat_map(nodes, fn node -> Map.get(node, "messages", []) end)
  end

  defp extract_messages(_), do: []
end
