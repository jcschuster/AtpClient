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

  # Like `theorem_signals/0`, but for the per-lemma classifier: adds the
  # alternate "Found proof" spelling some tools emit, and reverses the
  # gave_up/timeout precedence (a `timed out` message at a single lemma
  # line is reported as a timeout even when accompanied by "No proof
  # found"). The trailing error-kind check fires from `classify_text/1`.
  defp lemma_text_signals do
    [
      {&nitpick_counterexample?/1, :csat},
      {&quickcheck_counterexample?/1, :csat},
      {&nitpick_model?/1, :sat},
      {&quickcheck_model?/1, :sat},
      {&found_a_proof?/1, :thm},
      {&found_proof?/1, :thm},
      {&timeout?/1, :timeout},
      {&out_of_memory?/1, :out_of_resources},
      {&gave_up?/1, :gave_up}
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
  Per-lemma result returned by `per_lemma_results/2`.

    * `line` — source line in the theory file as reported by Isabelle; `nil`
      when the underlying message carries no position. If the theory was
      auto-wrapped by `prove_lemmas/4`, this is already adjusted to the
      caller's line numbering (body line 1 = 1, not 2).
    * `name` — lemma name extracted from Isabelle's completion message, or
      `nil` for anonymous lemmas, sledgehammer/nitpick verdicts (which
      Isabelle does not tag with the lemma name), and unnamed error entries.
    * `result` — any value of `atp_result/0`. The same signal-table
      classifier used by `interpret_isabelle_result/1` runs per line, so
      `sledgehammer ... oops` and `nitpick` verdicts surface as
      `{:ok, :thm}` / `{:ok, :csat}` / `{:ok, :sat}` / `{:ok, :gave_up}` /
      `{:ok, :timeout}` / `{:ok, :out_of_resources}` instead of collapsing
      to `:gave_up`.
  """
  @type lemma_result :: %{
          line: non_neg_integer() | nil,
          name: String.t() | nil,
          result: atp_result()
        }

  @doc """
  Parses a finished `use_theories` payload into one entry per lemma.

  Returns a list of `t:lemma_result/0` maps sorted by line number. Messages
  are grouped by their reported `pos.line` and each group is classified in
  this order:

    * Isabelle's `"theorem name:"` completion notification → `{:ok, :thm}`,
      with `name` extracted from the message;
    * `"Nitpick found a counterexample"` → `{:ok, :csat}`;
    * `"Nitpick found a model"` → `{:ok, :sat}`;
    * Sledgehammer `"found a proof"` → `{:ok, :thm}` (name `nil` — the
      message does not carry the lemma name);
    * `"timed out"` / `"TIMEOUT"` → `{:ok, :timeout}`;
    * `"Out of memory"` → `{:ok, :out_of_resources}`;
    * `"Nitpick found no …"` / `"No proof found"` → `{:ok, :gave_up}`;
    * any other error-kind message at this line → `{:ok, :gave_up}`;
    * groups with none of the above produce no entry.

  Groups with `pos.line == nil` are classified the same way; the resulting
  entry carries `line: nil`.

  Pass `line_offset: n` to subtract `n` from all Isabelle-reported line
  numbers. `AtpClient.Isabelle.prove_lemmas/4` uses this to undo the +1 shift
  introduced by auto-wrapping.
  """
  @spec per_lemma_results(map(), keyword()) :: [lemma_result()]
  def per_lemma_results(payload, opts \\ []) when is_map(payload) do
    offset = Keyword.get(opts, :line_offset, 0)

    payload
    |> extract_messages()
    |> Enum.group_by(&get_in(&1, ["pos", "line"]))
    |> Enum.flat_map(fn {line, msgs} ->
      case classify_line(msgs) do
        nil -> []
        {result, name} -> [%{line: adjust(line, offset), name: name, result: {:ok, result}}]
      end
    end)
    |> Enum.sort_by(&(&1.line || 0))
  end

  defp classify_line(messages) do
    case find_theorem_name(messages) do
      {:found, name} -> {:thm, name}
      :no_theorem -> classify_text(messages)
    end
  end

  defp classify_text(messages) do
    text = Enum.map_join(messages, "\n", &Map.get(&1, "message", ""))

    case scan(text, lemma_text_signals()) || error_kind_signal(messages) do
      nil -> nil
      status -> {status, nil}
    end
  end

  defp error_kind_signal(messages) do
    if Enum.any?(messages, &(Map.get(&1, "kind") == "error")), do: :gave_up
  end

  defp find_theorem_name(messages) do
    Enum.find_value(messages, :no_theorem, fn msg ->
      text = Map.get(msg, "message", "")
      if theorem_at_start?(text), do: {:found, theorem_name(text)}
    end)
  end

  defp theorem_name("theorem " <> rest), do: rest |> String.split(":") |> hd() |> String.trim()
  defp theorem_name(_), do: nil

  defp adjust(nil, _offset), do: nil
  defp adjust(line, 0), do: line
  defp adjust(line, offset), do: line - offset

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
