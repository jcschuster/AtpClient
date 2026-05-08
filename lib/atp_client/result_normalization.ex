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

  Classification combines structural and textual signals from the payload:

    * a "Nitpick found a counterexample" message yields `{:ok, :csat}`;
    * a "Nitpick found a model" message yields `{:ok, :sat}`;
    * a Sledgehammer "found a proof" message yields `{:ok, :thm}`;
    * a "timed out" / "TIMEOUT" message yields `{:ok, :timeout}`;
    * a "Out of memory" message yields `{:ok, :out_of_resources}`;
    * otherwise, if the payload reports `ok: true` with no top-level errors and
      every theory node's `status.ok` is true, all proofs were discharged →
      `{:ok, :thm}`. This covers plain `by auto`, `by simp`, structured
      `proof ... qed` blocks, and anything else that closes the goal without
      going through Sledgehammer or Nitpick;
    * remaining cases (finished with errors, or unclassifiable text) yield
      `{:ok, :gave_up}`.

  Failed tasks should be surfaced through `AtpClient.Isabelle.prove_theory/4`'s
  `{:error, {:isabelle_failed, _, _}}` channel and never reach this function.
  """
  @spec interpret_isabelle_result(map()) :: atp_result()
  def interpret_isabelle_result(payload) when is_map(payload) do
    text = extract_text(payload)

    status =
      check_tool_signals(text) ||
        check_structural_signals(payload) ||
        :gave_up

    {:ok, status}
  end

  defp check_tool_signals(text) do
    cond do
      nitpick_found?(text, "counterexample") -> :csat
      nitpick_found?(text, "model") -> :sat
      String.contains?(text, "found a proof") -> :thm
      gave_up?(text) -> :gave_up
      timeout?(text) -> :timeout
      String.contains?(text, "Out of memory") -> :out_of_resources
      true -> nil
    end
  end

  defp nitpick_found?(text, what),
    do: String.contains?(text, "Nitpick found a") and String.contains?(text, what)

  defp gave_up?(text),
    do: String.contains?(text, "Nitpick found no") or String.contains?(text, "No proof found")

  defp timeout?(text),
    do: String.contains?(text, "timed out") or String.contains?(text, "TIMEOUT")

  defp check_structural_signals(payload) do
    ok? = Map.get(payload, "ok", false)
    no_errors? = Map.get(payload, "errors", []) == []

    if ok? and no_errors? and all_nodes_ok?(payload) do
      :thm
    else
      nil
    end
  end

  defp all_nodes_ok?(%{"nodes" => nodes}) when is_list(nodes) and nodes != [] do
    Enum.all?(nodes, fn node ->
      case Map.get(node, "status") do
        %{"ok" => true, "failed" => 0} -> true
        %{"ok" => true} -> true
        _ -> false
      end
    end)
  end

  defp all_nodes_ok?(_), do: false

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

  defp extract_text(%{"nodes" => nodes}) when is_list(nodes) do
    nodes
    |> Enum.flat_map(fn node -> Map.get(node, "messages", []) end)
    |> Enum.map_join("\n", fn msg -> Map.get(msg, "message", "") end)
  end

  defp extract_text(_), do: ""
end
