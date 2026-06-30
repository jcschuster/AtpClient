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

  Consumers that want a fixed four-way switch (UIs, MCP integrations) can
  call `classify/1` to collapse the full SZS vocabulary down to
  `:proved | :disproved | :inconclusive | :error`.
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

  @typedoc """
  Coarse four-way triage produced by `classify/1`.

    * `:proved` — the prover affirms the conjecture.
    * `:disproved` — the prover affirms a counter-model or the negation.
    * `:inconclusive` — the prover finished without a verdict on the
      conjecture, or with a Success answer that does not settle the
      conjecture (e.g. `:no_consequence`, `:equi_satisfiable`).
    * `:error` — something prevented the prover from running, or it
      reported its own error (SZS `Error` / `InputError`).
  """
  @type verdict :: :proved | :disproved | :inconclusive | :error

  @proved_atoms ~w(
    theorem
    unsatisfiable
    contradictory_axioms
    tautology
    tautologous_conclusion
    equivalent
    weaker_conclusion
  )a

  @disproved_atoms ~w(
    counter_satisfiable
    satisfiable
    counter_theorem
    counter_equivalent
    equivalent_counter_theorem
  )a

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
  # SZS status line. Each pattern is mapped to the closest *honest* SZS atom
  # the prover would have printed had it complied with the ontology — e.g.
  # SPASS's "Completion found" means a saturated, contradiction-free clause
  # set was reached, i.e. `:satisfiable`, not `:gave_up`. Callers running a
  # negated-conjecture refutation pipeline (Sledgehammer-style) should treat
  # `:satisfiable` here as a counter-model to the original goal.
  @prover_specific_results [
    # Alt-Ergo
    {": Valid", {:ok, :theorem}},
    {": Timeout", {:ok, :timeout}},
    {": Unknown", {:ok, :unknown}},

    # E
    {"Failure: Resource limit exceeded (time)", {:ok, :timeout}},
    {"time limit exceeded", {:ok, :timeout}},

    # iProver: a CNFRefutation literally exhibits unsatisfiability of the
    # clause set; map to :unsatisfiable, not :theorem.
    {"% SZS output start CNFRefutation", {:ok, :unsatisfiable}},

    # LEO-II
    {"CPU time limit exceeded, terminating", {:ok, :timeout}},
    {"No.of.Axioms", {:ok, :gave_up}},

    # SPASS — input-error patterns are prover verdicts (SZS InputError),
    # so they go in the {:ok, _} channel; "Please report this error" is a
    # SPASS internal failure that we cannot trust to be a verdict.
    {"SPASS beiseite: Completion found", {:ok, :satisfiable}},
    {"SPASS beiseite: Ran out of time", {:ok, :timeout}},
    {"SPASS beiseite: Maximal number of loops exceeded", {:ok, :resource_out}},
    {"No formulae and clauses found in input file", {:ok, :input_error}},
    {"Undefined symbol", {:ok, :input_error}},
    {"Free Variable", {:ok, :input_error}},
    {"Please report this error", {:error, :internal_error}},

    # Vampire
    {"UNPROVABLE", {:ok, :gave_up}},
    {"CANNOT PROVE", {:ok, :gave_up}},
    {"Satisfiability detected", {:ok, :satisfiable}},
    {"Termination reason: Satisfiable", {:ok, :satisfiable}},
    {"Aborted by signal SIGINT", {:ok, :forced}},

    # Waldmeister — same channel split: input rejection is a verdict,
    # a SegFault is not.
    {"Too many function symbols", {:ok, :resource_out}},
    {"****  Unexpected end of file.", {:ok, :input_error}},
    {"Unrecoverable Segmentation Fault", {:error, :internal_error}}
  ]

  @doc """
  Interprets the output of provers that follow the SZS ontology (including
  those available on SystemOnTPTP) into the standardized representation.

  Three layers run in order:

    1. Prover-specific patterns for solvers that do not (always) emit an SZS
       status line — Alt-Ergo, E, iProver, LEO-II, SPASS, Vampire,
       Waldmeister. Mirrors the sledgehammer source
       (https://github.com/seL4/isabelle/blob/master/src/HOL/Tools/Sledgehammer/sledgehammer_atp_systems.ML)
       but maps to the *honest* SZS atom rather than sledgehammer's
       negated-conjecture interpretation: e.g. SPASS "Completion found"
       becomes `{:ok, :satisfiable}`, not `{:ok, :gave_up}`.
    2. The explicit SZS table (`@known_szs_results`) recognises every status
       in `t:szs_success/0` and `t:szs_no_success/0` from a
       `"SZS status <Name>"` or `" says <Name>"` substring.
    3. A permissive fallback converts any remaining
       `"SZS status <CamelCase>"` (or `" says <CamelCase>"`) line to its
       snake-case atom, so SZS additions like `EquivalentTheorem` become
       `{:ok, :equivalent_theorem}` without a code change.

  Output that none of the three layers matches comes back as
  `{:error, {:unrecognized_output, res_str}}`.
  """
  @spec interpret_result(String.t()) :: atp_result()
  def interpret_result(res_str) do
    prover_specific_match(res_str) || szs_line_match(res_str) ||
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
  Collapses an `t:atp_result/0` into the four-way `t:verdict/0` triage —
  for callers that don't need the full SZS vocabulary (Smart Cells,
  MCP-style integrations, "did it prove the conjecture?" UI tags).

  Bucketing follows the SZS Success/NoSuccess hierarchy:

    * `:proved` — `:theorem`, `:unsatisfiable` (refutation success on the
      negated conjecture), `:contradictory_axioms`, `:tautology`,
      `:tautologous_conclusion`, `:equivalent`, `:weaker_conclusion`.
    * `:disproved` — `:counter_satisfiable`, `:satisfiable` (model of the
      negated conjecture), `:counter_theorem`, `:counter_equivalent`,
      `:equivalent_counter_theorem`.
    * `:inconclusive` — every NoSuccess atom outside the Error sub-tree
      (`:gave_up`, `:unknown`, `:incomplete`, `:timeout`, `:resource_out`,
      `:memory_out`, `:forced`, `:user`, `:inappropriate`), plus the
      Success atoms that do not pick a side on the conjecture
      (`:no_consequence`, `:equi_satisfiable`). Unknown SZS atoms from
      `interpret_result/1`'s permissive fallback also land here — being
      conservative is safer than guessing.
    * `:error` — any `{:error, _}` reason, plus a prover-reported
      `{:ok, :error}` / `{:ok, :input_error}` SZS verdict.

  Callers that need to distinguish e.g. `:theorem` (Isabelle/model-checker)
  from `:unsatisfiable` (TPTP refutation) should keep pattern-matching on
  `t:szs_status/0` directly; that distinction is exactly what this helper
  intentionally discards.
  """
  @spec classify(atp_result()) :: verdict()
  def classify({:ok, atom}) when atom in @proved_atoms, do: :proved
  def classify({:ok, atom}) when atom in @disproved_atoms, do: :disproved
  def classify({:ok, :error}), do: :error
  def classify({:ok, :input_error}), do: :error
  def classify({:ok, _szs_atom}), do: :inconclusive
  def classify({:error, _reason}), do: :error

  @doc """
  Interprets the `result` payload of a finished `use_theories` task — the map
  returned in `%IsabelleClient.Task{status: :finished, result: ...}`, with
  top-level keys `"ok"`, `"errors"`, `"nodes"`, etc.

  Classification is driven by the messages Isabelle emits, not by whether the
  task finished without errors. Isabelle is goal-directed (it proves stated
  conjectures), so successful proofs map to `:theorem` rather than
  `:unsatisfiable`, and a refuted goal maps to `:counter_satisfiable`:

    * a "Nitpick / Quickcheck found a counterexample" message yields
      `{:ok, :counter_satisfiable}`;
    * a "Nitpick / Quickcheck found a model" message yields
      `{:ok, :satisfiable}`;
    * a Sledgehammer "found a proof" message yields `{:ok, :theorem}`;
    * any message starting with `"theorem "` (Isabelle's proof-completion
      notification, emitted for every discharged goal regardless of the tactic
      used) yields `{:ok, :theorem}`;
    * a "timed out" / "TIMEOUT" message yields `{:ok, :timeout}`;
    * a "Out of memory" message yields `{:ok, :memory_out}`;
    * remaining cases yield `{:ok, :gave_up}`.

  Failed tasks should be surfaced through `AtpClient.Isabelle.prove_theory/4`'s
  `{:error, {:isabelle_failed, _, _}}` channel and never reach this function.
  """
  @spec interpret_isabelle_result(map()) :: atp_result()
  def interpret_isabelle_result(payload) when is_map(payload) do
    text = extract_text(payload)
    {:ok, scan(text, theorem_signals()) || :gave_up}
  end

  # Ordered list of `{predicate, status}` tuples scanned by `scan/2`. The
  # first matching predicate wins, so the order encodes precedence: tool
  # verdicts (nitpick / quickcheck / sledgehammer) before the generic
  # `theorem` completion, and `gave_up` before `timeout` so a "No proof
  # found, timed out" message classifies as gave_up.
  defp theorem_signals do
    [
      {&nitpick_counterexample?/1, :counter_satisfiable},
      {&quickcheck_counterexample?/1, :counter_satisfiable},
      {&nitpick_model?/1, :satisfiable},
      {&quickcheck_model?/1, :satisfiable},
      {&found_a_proof?/1, :theorem},
      {&theorem_proved?/1, :theorem},
      {&gave_up?/1, :gave_up},
      {&timeout?/1, :timeout},
      {&out_of_memory?/1, :memory_out}
    ]
  end

  defp scan(text, signals) do
    Enum.find_value(signals, fn {predicate, status} ->
      if predicate.(text), do: status
    end)
  end

  defp theorem_proved?(text),
    do:
      theorem_at_start?(text) or
        String.contains?(text, "\ntheorem ") or
        String.contains?(text, "\ntheorem:")

  defp theorem_at_start?(text),
    do: String.starts_with?(text, "theorem ") or String.starts_with?(text, "theorem:")

  defp nitpick_counterexample?(text), do: nitpick_found?(text, "counterexample")
  defp quickcheck_counterexample?(text), do: quickcheck_found?(text, "counterexample")
  defp nitpick_model?(text), do: nitpick_found?(text, "model")
  defp quickcheck_model?(text), do: quickcheck_found?(text, "model")

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
  Specification for one lemma in a generated theory body, as computed by
  `AtpClient.Isabelle.lemma_specs/1`.

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
  # current proof state, not a success notification. The accompanying
  # `Failed to finish proof` error tells us the goal stayed open.
  defp proof_method_failure?(messages) do
    Enum.any?(messages, fn msg ->
      Map.get(msg, "kind") == "error" and
        msg
        |> Map.get("message", "")
        |> String.contains?("Failed to finish proof")
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
