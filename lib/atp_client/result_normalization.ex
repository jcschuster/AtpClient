defmodule AtpClient.ResultNormalization do
  @moduledoc """
  Interprets output from various provers into a standardized format.

  The TPTP-oriented prover outputs (used by SystemOnTPTP and StarExec backends
  when solvers follow the SZS Ontology) are interpreted by `interpret_result/1`.
  Isabelle `use_theories` results are interpreted by
  `interpret_isabelle_result/1`.
  """

  @typedoc "Standardized format for ATP outputs."
  @type atp_result :: {:ok, success_t()} | {:error, failure_t()}

  @typedoc "Expected ATP results"
  @type success_t ::
          :thm
          | :csat
          | :sat
          | :timeout
          | :out_of_resources
          | :gave_up
          | :interrupted

  @typedoc "Unexpected failures (including parsing errors of user input)"
  @type failure_t ::
          :internal_error
          | :malformed_input
          | {:prover_not_found, String.t()}
          | {:unrecognized_output, String.t()}

  @known_szs_results [
    {"Theorem", {:ok, :thm}},
    {"Unsatisfiable", {:ok, :thm}},
    {"CounterSatisfiable", {:ok, :csat}},
    {"Satisfiable", {:ok, :csat}},
    {"GaveUp", {:ok, :gave_up}},
    {"Unknown", {:ok, :gave_up}},
    {"Incomplete", {:ok, :gave_up}},
    {"Timeout", {:ok, :timeout}},
    {"ResourceOut", {:ok, :out_of_resources}},
    {"MemoryOut", {:ok, :out_of_resources}},
    {"Forced", {:ok, :interrupted}},
    {"User", {:ok, :interrupted}},
    {"Inappropriate", {:error, :malformed_input}}
  ]

  @prover_specific_results [
    # Alt-Ergo
    {": Valid", {:ok, :thm}},
    {": Timeout", {:ok, :timeout}},
    {": Unknown", {:ok, :gave_up}},

    # E
    {"Failure: Resource limit exceeded (time)", {:ok, :timeout}},
    {"time limit exceeded", {:ok, :timeout}},

    # iProver
    {"% SZS output start CNFRefutation", {:ok, :thm}},

    # LEO-II
    {"CPU time limit exceeded, terminating", {:ok, :timeout}},
    {"No.of.Axioms", {:ok, :gave_up}},

    # SPASS
    {"SPASS beiseite: Completion found", {:ok, :gave_up}},
    {"SPASS beiseite: Ran out of time", {:ok, :timeout}},
    {"SPASS beiseite: Maximal number of loops exceeded", {:ok, :out_of_resources}},
    {"No formulae and clauses found in input file", {:ok, :csat}},
    {"Undefined symbol", {:error, :malformed_input}},
    {"Free Variable", {:error, :malformed_input}},
    {"Please report this error", {:error, :internal_error}},

    # Vampire
    {"UNPROVABLE", {:ok, :gave_up}},
    {"CANNOT PROVE", {:ok, :gave_up}},
    {"Satisfiability detected", {:ok, :csat}},
    {"Termination reason: Satisfiable", {:ok, :csat}},
    {"Aborted by signal SIGINT", {:ok, :interrupted}},

    # Waldmeister
    {"Too many function symbols", {:ok, :out_of_resources}},
    {"****  Unexpected end of file.", {:error, :malformed_input}},
    {"Unrecoverable Segmentation Fault", {:error, :internal_error}}
  ]

  @doc """
  Interprets the output of provers that follow the SZS ontology (including
  those available on SystemOnTPTP) into the standardized representation.

  This might not work for all available systems but at least for those available
  through the `sledgehammer` tool in Isabelle/HOL. Much of the result
  interpretation is taken directly from the sledgehammer source code
  (https://github.com/seL4/isabelle/blob/master/src/HOL/Tools/Sledgehammer/sledgehammer_atp_systems.ML).
  """
  @spec interpret_result(String.t()) :: atp_result()
  def interpret_result(res_str) do
    mappings =
      @prover_specific_results ++
        Enum.flat_map(@known_szs_results, fn {msg, res} ->
          for prefix <- ["SZS status ", " says "], do: {prefix <> msg, res}
        end)

    result =
      Enum.find_value(mappings, fn {pattern, mapped_result} ->
        if String.contains?(res_str, pattern), do: mapped_result
      end)

    result || {:error, {:unrecognized_output, res_str}}
  end

  @doc """
  Interprets the `result` payload of a finished `use_theories` task — the map
  returned in `%IsabelleClient.Task{status: :finished, result: ...}`, with
  top-level keys `"ok"`, `"errors"`, `"nodes"`, etc.

  Classification is driven by the messages Isabelle emits, not by whether the
  task finished without errors:

    * a "Nitpick found a counterexample" message yields `{:ok, :csat}`;
    * a "Nitpick found a model" message yields `{:ok, :sat}`;
    * a Sledgehammer "found a proof" message yields `{:ok, :thm}`;
    * any message starting with `"theorem "` (Isabelle's proof-completion
      notification, emitted for every discharged goal regardless of the tactic
      used) yields `{:ok, :thm}`;
    * a "timed out" / "TIMEOUT" message yields `{:ok, :timeout}`;
    * a "Out of memory" message yields `{:ok, :out_of_resources}`;
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
      {&nitpick_counterexample?/1, :csat},
      {&quickcheck_counterexample?/1, :csat},
      {&nitpick_model?/1, :sat},
      {&quickcheck_model?/1, :sat},
      {&found_a_proof?/1, :thm},
      {&theorem_proved?/1, :thm},
      {&gave_up?/1, :gave_up},
      {&timeout?/1, :timeout},
      {&out_of_memory?/1, :out_of_resources}
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
  false `:csat` verdicts when one message read `Nitpick found a model`
  and another read `Nitpick found no counterexample` (the
  `"Nitpick found a" + "counterexample"` substring test fires across the
  two), and false `:thm` verdicts when `by auto` failed on a False goal
  (Isabelle still echoes `theorem name: <goal>` at the `by` position next
  to the `Failed to finish proof` error).

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

    1. `:csat` (Nitpick / Quickcheck counter-example) — disproves the
       goal; dominates any concurrent proof attempt.
    2. `:thm` from a sledgehammer / metis `"found a proof"` line.
    3. `:sat` (Nitpick / Quickcheck model).
    4. Proof-method failure veto — an `error`-kind message containing
       `"Failed to finish proof"` cancels a `theorem name:` verdict from
       the same bucket.
    5. `:thm` from a `theorem name:` completion notification.
    6. `:timeout`, `:out_of_resources`, then `:gave_up`.

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
      :csat in verdicts -> :csat
      :thm_proof in verdicts -> :thm
      :sat in verdicts -> :sat
      proof_method_failure?(messages) -> :gave_up
      :thm_completion in verdicts -> :thm
      :timeout in verdicts -> :timeout
      :out_of_resources in verdicts -> :out_of_resources
      :gave_up_hint in verdicts -> :gave_up
      any_error?(messages) -> :gave_up
      true -> :gave_up
    end
  end

  defp classify_lemma_message(msg) do
    text = Map.get(msg, "message", "")

    cond do
      nitpick_found?(text, "counterexample") -> :csat
      quickcheck_found?(text, "counterexample") -> :csat
      nitpick_found?(text, "model") -> :sat
      quickcheck_found?(text, "model") -> :sat
      found_a_proof?(text) -> :thm_proof
      found_proof?(text) -> :thm_proof
      timeout?(text) -> :timeout
      out_of_memory?(text) -> :out_of_resources
      gave_up?(text) -> :gave_up_hint
      theorem_at_start?(text) -> :thm_completion
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
