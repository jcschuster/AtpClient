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
    {:ok, check_tool_signals(text) || :gave_up}
  end

  defp check_tool_signals(text) do
    cond do
      nitpick_found?(text, "counterexample") -> :csat
      nitpick_found?(text, "model") -> :sat
      String.contains?(text, "found a proof") -> :thm
      theorem_proved?(text) -> :thm
      gave_up?(text) -> :gave_up
      timeout?(text) -> :timeout
      String.contains?(text, "Out of memory") -> :out_of_resources
      true -> nil
    end
  end

  defp theorem_proved?(text),
    do: theorem_at_start?(text) or
          String.contains?(text, "\ntheorem ") or
          String.contains?(text, "\ntheorem:")

  defp theorem_at_start?(text),
    do: String.starts_with?(text, "theorem ") or String.starts_with?(text, "theorem:")

  defp nitpick_found?(text, what),
    do: String.contains?(text, "Nitpick found a") and String.contains?(text, what)

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
      when the message carries no position. If the theory was auto-wrapped by
      `prove_lemmas/4`, this is already adjusted to the caller's line numbering
      (body line 1 = 1, not 2).
    * `name` — lemma name extracted from Isabelle's completion message, or
      `nil` for anonymous lemmas.
    * `result` — same values as `atp_result/0`; currently either `{:ok, :thm}`
      (theorem proved) or `{:ok, :gave_up}` (proof obligation present but
      Isabelle could not discharge it).
  """
  @type lemma_result :: %{
          line: non_neg_integer() | nil,
          name: String.t() | nil,
          result: atp_result()
        }

  @doc """
  Parses a finished `use_theories` payload into one entry per lemma.

  Returns a list of `t:lemma_result/0` maps sorted by line number:

    * Every `"theorem …"` writeln message becomes a `{:ok, :thm}` entry;
    * Every error-kind message at a line not already covered by a theorem
      completion becomes a `{:ok, :gave_up}` entry (one per distinct line).

  Pass `line_offset: n` to subtract `n` from all Isabelle-reported line
  numbers. `AtpClient.Isabelle.prove_lemmas/4` uses this to undo the +1 shift
  introduced by auto-wrapping.
  """
  @spec per_lemma_results(map(), keyword()) :: [lemma_result()]
  def per_lemma_results(payload, opts \\ []) when is_map(payload) do
    offset = Keyword.get(opts, :line_offset, 0)
    messages = extract_messages(payload)

    proved = Enum.flat_map(messages, &theorem_entry(&1, offset))
    proved_lines = MapSet.new(proved, & &1.line)

    failed =
      messages
      |> Enum.filter(&(Map.get(&1, "kind") == "error"))
      |> Enum.map(fn msg -> %{line: adjust(get_in(msg, ["pos", "line"]), offset), name: nil, result: {:ok, :gave_up}} end)
      |> Enum.reject(fn %{line: l} -> l == nil or MapSet.member?(proved_lines, l) end)
      |> Enum.uniq_by(& &1.line)

    (proved ++ failed) |> Enum.sort_by(&(&1.line || 0))
  end

  defp theorem_entry(msg, offset) do
    text = Map.get(msg, "message", "")

    if theorem_at_start?(text) do
      [%{line: adjust(get_in(msg, ["pos", "line"]), offset), name: theorem_name(text), result: {:ok, :thm}}]
    else
      []
    end
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
