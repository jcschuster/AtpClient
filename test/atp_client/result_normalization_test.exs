defmodule AtpClient.ResultNormalizationTest do
  use ExUnit.Case, async: true

  alias AtpClient.ResultNormalization

  # Helpers to build realistic use_theories payloads.
  defp payload(nodes, opts \\ []) do
    %{
      "ok" => Keyword.get(opts, :ok, true),
      "errors" => Keyword.get(opts, :errors, []),
      "nodes" => nodes
    }
  end

  defp theory_node(messages, opts \\ []) do
    %{
      "node_name" => Keyword.get(opts, :name, "T"),
      "messages" => messages,
      "status" => %{"ok" => Keyword.get(opts, :ok, true), "failed" => 0}
    }
  end

  defp msg(text, kind \\ "writeln"),
    do: %{"kind" => kind, "message" => text}

  describe "interpret_isabelle_result/1 — theorem detection" do
    test "recognizes proof-completion message for a named lemma" do
      p = payload([theory_node([msg("theorem foo:\n  P ∨ ¬ P")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :theorem}
    end

    test "recognizes proof-completion message for an anonymous lemma" do
      p = payload([theory_node([msg("theorem:\n  True")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :theorem}
    end

    test "recognizes theorem message that is not the first message" do
      p = payload([theory_node([msg("Auto Quickcheck found no counterexample"), msg("theorem foo:\n  P")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :theorem}
    end

    test "recognizes multiple theorem messages (multi-lemma theory)" do
      p = payload([theory_node([msg("theorem foo:\n  P"), msg("theorem bar:\n  Q")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :theorem}
    end

    test "returns :gave_up when theory compiles but no theorem message is emitted" do
      p = payload([theory_node([])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :gave_up}
    end

    test "returns :gave_up when ok:true but errors present and no theorem message" do
      p = payload([theory_node([msg("Type error", "error")])], ok: false)
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :gave_up}
    end
  end

  describe "interpret_isabelle_result/1 — Sledgehammer / Nitpick signals" do
    test "Sledgehammer found a proof" do
      p = payload([theory_node([msg("found a proof")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :theorem}
    end

    test "Nitpick found a counterexample → :counter_satisfiable" do
      p = payload([theory_node([msg("Nitpick found a counterexample")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :counter_satisfiable}
    end

    test "Nitpick found a model → :satisfiable" do
      p = payload([theory_node([msg("Nitpick found a model")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :satisfiable}
    end

    test "Nitpick found no counterexample without a theorem message → :gave_up" do
      p = payload([theory_node([msg("Nitpick found no counterexample")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :gave_up}
    end

    test "timed out → :timeout" do
      p = payload([theory_node([msg("Sledgehammer: timed out")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :timeout}
    end

    test "Out of memory → :memory_out" do
      p = payload([theory_node([msg("Out of memory")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :memory_out}
    end
  end

  describe "interpret_isabelle_result/1 — no false positives" do
    test "message containing 'theorem' mid-sentence does not trigger :theorem" do
      p = payload([theory_node([msg("The theorem prover gave up")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :gave_up}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # per_lemma_results/3
  # ──────────────────────────────────────────────────────────────────────────

  defp msg_at(text, line, kind \\ "writeln"),
    do: %{"kind" => kind, "message" => text, "pos" => %{"line" => line}}

  defp spec(name, range), do: %{name: name, range: range}

  describe "per_lemma_results/3 — basic cases" do
    test "empty specs returns empty list regardless of payload" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 2)])])
      assert ResultNormalization.per_lemma_results(p, []) == []
    end

    test "spec with no in-range messages buckets to :gave_up" do
      p = payload([theory_node([])])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 2..3)]) == [
               %{name: "g", result: {:ok, :gave_up}}
             ]
    end

    test "single named proved lemma — theorem completion in range" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 2)])])

      assert ResultNormalization.per_lemma_results(p, [spec("foo", 2..3)]) == [
               %{name: "foo", result: {:ok, :theorem}}
             ]
    end

    test "multiple lemmas — order follows specs, not message order" do
      p =
        payload([
          theory_node([
            msg_at("theorem bar:\n  Q", 5),
            msg_at("theorem foo:\n  P", 2)
          ])
        ])

      specs = [spec("foo", 2..4), spec("bar", 5..7)]

      assert ResultNormalization.per_lemma_results(p, specs) == [
               %{name: "foo", result: {:ok, :theorem}},
               %{name: "bar", result: {:ok, :theorem}}
             ]
    end

    test "messages without pos.line are ignored" do
      p = payload([theory_node([msg("theorem foo:\n  P")])])

      assert ResultNormalization.per_lemma_results(p, [spec("foo", 1..3)]) == [
               %{name: "foo", result: {:ok, :gave_up}}
             ]
    end

    test "messages outside any spec range do not affect verdicts" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 99)])])

      assert ResultNormalization.per_lemma_results(p, [spec("foo", 2..3)]) == [
               %{name: "foo", result: {:ok, :gave_up}}
             ]
    end
  end

  describe "per_lemma_results/3 — verdict precedence" do
    test "Nitpick counterexample dominates a sledgehammer proof in the same bucket" do
      p =
        payload([
          theory_node([
            msg_at("Sledgehammer: found a proof", 3),
            msg_at("Nitpick found a counterexample", 3)
          ])
        ])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :counter_satisfiable}}
             ]
    end

    test "'found a proof' beats 'Nitpick found a model' in the same bucket" do
      p =
        payload([
          theory_node([
            msg_at("Sledgehammer: found a proof", 3),
            msg_at("Nitpick found a model", 3)
          ])
        ])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :theorem}}
             ]
    end

    test "Nitpick model classifies as :satisfiable" do
      p = payload([theory_node([msg_at("Nitpick found a model", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :satisfiable}}
             ]
    end

    test "'Failed to finish proof' error vetoes a theorem echo at the same position" do
      # Regression for `by auto` against False: Isabelle echoes
      # `theorem name: <goal>` at the `by` line even though the goal stays open.
      p =
        payload([
          theory_node([
            msg_at("theorem a:\n  P ∧ ¬ P", 3),
            msg_at("Failed to finish proof", 3, "error")
          ])
        ])

      assert ResultNormalization.per_lemma_results(p, [spec("a", 3..3)]) == [
               %{name: "a", result: {:ok, :gave_up}}
             ]
    end

    test "theorem completion without a failure error counts as :theorem" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("foo", 3..3)]) == [
               %{name: "foo", result: {:ok, :theorem}}
             ]
    end

    test "timed out signal classifies as :timeout" do
      p = payload([theory_node([msg_at("Sledgehammer: timed out", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :timeout}}
             ]
    end

    test "Out of memory classifies as :memory_out" do
      p = payload([theory_node([msg_at("Out of memory", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :memory_out}}
             ]
    end

    test "'No proof found' classifies as :gave_up" do
      p = payload([theory_node([msg_at("Sledgehammer: No proof found", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :gave_up}}
             ]
    end

    test "error-kind message without classifying text yields :gave_up" do
      p = payload([theory_node([msg_at("some unspecified error", 3, "error")])])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :gave_up}}
             ]
    end
  end

  describe "per_lemma_results/3 — multi-message bug regressions" do
    test "Nitpick model + Nitpick found no counterexample → :satisfiable, not :counter_satisfiable" do
      # The pre-fix classifier concatenated both messages and ran the
      # `"Nitpick found a" + "counterexample"` substring test across the
      # join, producing a spurious `:counter_satisfiable`. Now each message
      # is scanned individually, so the model wins.
      p =
        payload([
          theory_node([
            msg_at("Nitpick found a model", 3),
            msg_at("Nitpick found no counterexample", 3)
          ])
        ])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :satisfiable}}
             ]
    end
  end

  describe "per_lemma_results/3 — bucketing by range" do
    test "two lemmas, each gets exactly the messages in its range" do
      p =
        payload([
          theory_node([
            msg_at("theorem g1:\n  P", 2),
            msg_at("Nitpick found a counterexample", 5),
            msg_at("Sledgehammer: found a proof", 8)
          ])
        ])

      specs = [spec("g1", 2..4), spec("g2", 5..7), spec("g3", 8..10)]

      assert ResultNormalization.per_lemma_results(p, specs) == [
               %{name: "g1", result: {:ok, :theorem}},
               %{name: "g2", result: {:ok, :counter_satisfiable}},
               %{name: "g3", result: {:ok, :theorem}}
             ]
    end

    test "an in-range and out-of-range message stay separated" do
      p =
        payload([
          theory_node([
            msg_at("theorem g1:\n  P", 3),
            msg_at("theorem g2:\n  Q", 7)
          ])
        ])

      specs = [spec("g1", 3..5), spec("g2", 6..9)]

      assert ResultNormalization.per_lemma_results(p, specs) == [
               %{name: "g1", result: {:ok, :theorem}},
               %{name: "g2", result: {:ok, :theorem}}
             ]
    end
  end

  describe "per_lemma_results/3 — :line_offset option" do
    test "subtracts offset before bucketing" do
      # Body line 2 lands at on-disk line 3 after auto-wrap (+1 header line).
      p = payload([theory_node([msg_at("theorem foo:\n  P", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("foo", 2..2)], line_offset: 1) == [
               %{name: "foo", result: {:ok, :theorem}}
             ]
    end

    test "offset 0 leaves lines unchanged" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 2)])])

      assert ResultNormalization.per_lemma_results(p, [spec("foo", 2..2)], line_offset: 0) == [
               %{name: "foo", result: {:ok, :theorem}}
             ]
    end
  end

  describe "per_lemma_results/3 — :file option" do
    defp msg_in(text, line, file, kind \\ "writeln"),
      do: %{"kind" => kind, "message" => text, "pos" => %{"line" => line, "file" => file}}

    test "drops messages whose pos.file does not end with the given suffix" do
      # Phantom messages from TPTP.thy should not pollute the lemma bucket.
      p =
        payload([
          theory_node([
            msg_in("noise from imported theory", 3, "/srv/isa/TPTP.thy"),
            msg_in("theorem foo:\n  P", 3, "/srv/isa/Example.thy")
          ])
        ])

      assert ResultNormalization.per_lemma_results(
               p,
               [spec("foo", 3..3)],
               file: "/Example.thy"
             ) == [%{name: "foo", result: {:ok, :theorem}}]
    end

    test "messages with no pos.file are dropped when a :file filter is active" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 3)])])

      assert ResultNormalization.per_lemma_results(
               p,
               [spec("foo", 3..3)],
               file: "/Example.thy"
             ) == [%{name: "foo", result: {:ok, :gave_up}}]
    end

    test "with no :file filter, all positioned messages are kept" do
      p = payload([theory_node([msg_in("theorem foo:\n  P", 3, "/srv/isa/TPTP.thy")])])

      assert ResultNormalization.per_lemma_results(p, [spec("foo", 3..3)]) == [
               %{name: "foo", result: {:ok, :theorem}}
             ]
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # interpret_result/1 — SZS-faithful pass-through
  # ──────────────────────────────────────────────────────────────────────────

  describe "interpret_result/1 — SZS Ontology pass-through" do
    test "Theorem and Unsatisfiable are kept distinct" do
      assert ResultNormalization.interpret_result("% SZS status Theorem for x") ==
               {:ok, :theorem}

      assert ResultNormalization.interpret_result("% SZS status Unsatisfiable for x") ==
               {:ok, :unsatisfiable}
    end

    test "Satisfiable and CounterSatisfiable are kept distinct" do
      assert ResultNormalization.interpret_result("% SZS status Satisfiable for x") ==
               {:ok, :satisfiable}

      assert ResultNormalization.interpret_result("% SZS status CounterSatisfiable for x") ==
               {:ok, :counter_satisfiable}
    end

    test "NoSuccess statuses preserve their SZS names" do
      for {szs, atom} <- [
            {"GaveUp", :gave_up},
            {"Unknown", :unknown},
            {"Incomplete", :incomplete},
            {"Timeout", :timeout},
            {"ResourceOut", :resource_out},
            {"MemoryOut", :memory_out},
            {"Forced", :forced},
            {"User", :user},
            {"Inappropriate", :inappropriate}
          ] do
        assert ResultNormalization.interpret_result("% SZS status #{szs} for x") ==
                 {:ok, atom}
      end
    end

    test "ContradictoryAxioms is recognized" do
      assert ResultNormalization.interpret_result("% SZS status ContradictoryAxioms for x") ==
               {:ok, :contradictory_axioms}
    end

    test "Error and InputError (NoSuccess Error sub-tree) are recognized" do
      assert ResultNormalization.interpret_result("% SZS status Error for x") ==
               {:ok, :error}

      assert ResultNormalization.interpret_result("% SZS status InputError for x") ==
               {:ok, :input_error}
    end

    test "Less common Success atoms pass through with the correct snake_case name" do
      for {szs, atom} <- [
            {"Tautology", :tautology},
            {"TautologousConclusion", :tautologous_conclusion},
            {"WeakerConclusion", :weaker_conclusion},
            {"Equivalent", :equivalent},
            {"CounterEquivalent", :counter_equivalent},
            {"CounterTheorem", :counter_theorem},
            {"EquivalentCounterTheorem", :equivalent_counter_theorem},
            {"EquiSatisfiable", :equi_satisfiable},
            {"NoConsequence", :no_consequence}
          ] do
        assert ResultNormalization.interpret_result("% SZS status #{szs} for x") ==
                 {:ok, atom}
      end
    end

    test "longer/more-specific names take precedence over shorter prefixes" do
      # "ContradictoryAxioms" must not collapse onto "Theorem" via substring.
      assert ResultNormalization.interpret_result("% SZS status ContradictoryAxioms for x") ==
               {:ok, :contradictory_axioms}

      # "CounterSatisfiable" must not collapse onto "Satisfiable".
      assert ResultNormalization.interpret_result("% SZS status CounterSatisfiable for x") ==
               {:ok, :counter_satisfiable}

      # "InputError" must not collapse onto "Error".
      assert ResultNormalization.interpret_result("% SZS status InputError for x") ==
               {:ok, :input_error}
    end

    test "unmatched output flows through as {:error, {:unrecognized_output, _}}" do
      assert ResultNormalization.interpret_result("nothing helpful here") ==
               {:error, {:unrecognized_output, "nothing helpful here"}}
    end
  end

  describe "interpret_result/1 — permissive SZS fallback" do
    test "unrecognised SZS status passes through as snake_case atom" do
      # `EquivalentTheorem` is in the SZS Ontology but not in the explicit
      # table; the permissive fallback should still surface it.
      assert ResultNormalization.interpret_result("% SZS status EquivalentTheorem for x") ==
               {:ok, :equivalent_theorem}
    end

    test "permissive fallback respects 'says' prefix too" do
      assert ResultNormalization.interpret_result("FooProver says FiniteTheorem for problem") ==
               {:ok, :finite_theorem}
    end

    test "garbage after 'SZS status' does not match (strict CamelCase)" do
      # lowercase first character is not a valid SZS name
      assert ResultNormalization.interpret_result("SZS status theorem garbage") ==
               {:error, {:unrecognized_output, "SZS status theorem garbage"}}
    end

    test "explicit table wins over permissive fallback" do
      # Even though `Theorem` could match permissively too, the explicit
      # table entry takes precedence (proves we evaluate in the right order).
      assert ResultNormalization.interpret_result("% SZS status Theorem for x") ==
               {:ok, :theorem}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # classify/1 — four-way triage
  # ──────────────────────────────────────────────────────────────────────────

  describe "classify/1 — :proved bucket" do
    test "Theorem and Unsatisfiable both collapse to :proved" do
      assert ResultNormalization.classify({:ok, :theorem}) == :proved
      assert ResultNormalization.classify({:ok, :unsatisfiable}) == :proved
    end

    test "every documented :proved atom triages as :proved" do
      for atom <- [
            :theorem,
            :unsatisfiable,
            :contradictory_axioms,
            :tautology,
            :tautologous_conclusion,
            :equivalent,
            :weaker_conclusion
          ] do
        assert ResultNormalization.classify({:ok, atom}) == :proved,
               "expected #{inspect(atom)} → :proved"
      end
    end
  end

  describe "classify/1 — :disproved bucket" do
    test "Satisfiable and CounterSatisfiable both collapse to :disproved" do
      assert ResultNormalization.classify({:ok, :satisfiable}) == :disproved
      assert ResultNormalization.classify({:ok, :counter_satisfiable}) == :disproved
    end

    test "every documented :disproved atom triages as :disproved" do
      for atom <- [
            :counter_satisfiable,
            :satisfiable,
            :counter_theorem,
            :counter_equivalent,
            :equivalent_counter_theorem
          ] do
        assert ResultNormalization.classify({:ok, atom}) == :disproved,
               "expected #{inspect(atom)} → :disproved"
      end
    end
  end

  describe "classify/1 — :inconclusive bucket" do
    test "NoSuccess atoms outside the Error sub-tree triage as :inconclusive" do
      for atom <- [
            :gave_up,
            :unknown,
            :incomplete,
            :timeout,
            :resource_out,
            :memory_out,
            :forced,
            :user,
            :inappropriate
          ] do
        assert ResultNormalization.classify({:ok, atom}) == :inconclusive,
               "expected #{inspect(atom)} → :inconclusive"
      end
    end

    test "Success atoms that do not settle the conjecture are :inconclusive" do
      # NoConsequence proves the conjecture is *independent*, not refuted.
      # EquiSatisfiable is a preprocessing result, not a final answer.
      assert ResultNormalization.classify({:ok, :no_consequence}) == :inconclusive
      assert ResultNormalization.classify({:ok, :equi_satisfiable}) == :inconclusive
    end

    test "permissive-fallback atoms triage as :inconclusive (conservative)" do
      # An atom surfaced by the permissive SZS fallback (e.g. `:finite_theorem`)
      # is not on either explicit list — refuse to guess.
      assert ResultNormalization.classify({:ok, :finite_theorem}) == :inconclusive
      assert ResultNormalization.classify({:ok, :some_future_atom}) == :inconclusive
    end
  end

  describe "classify/1 — :error bucket" do
    test "{:error, _} reasons all triage as :error" do
      assert ResultNormalization.classify({:error, :internal_error}) == :error
      assert ResultNormalization.classify({:error, :input_error}) == :error
      assert ResultNormalization.classify({:error, {:prover_not_found, "ep"}}) == :error
      assert ResultNormalization.classify({:error, {:unrecognized_output, "?"}}) == :error
    end

    test "prover-reported SZS Error / InputError verdicts triage as :error" do
      assert ResultNormalization.classify({:ok, :error}) == :error
      assert ResultNormalization.classify({:ok, :input_error}) == :error
    end
  end

  describe "interpret_result/1 — prover-specific signals map to honest SZS atoms" do
    test "iProver CNFRefutation marker → :unsatisfiable (not :theorem)" do
      assert ResultNormalization.interpret_result("% SZS output start CNFRefutation") ==
               {:ok, :unsatisfiable}
    end

    test "SPASS Completion found → :satisfiable" do
      assert ResultNormalization.interpret_result("SPASS beiseite: Completion found") ==
               {:ok, :satisfiable}
    end

    test "SPASS unreadable input → {:ok, :input_error} (prover's SZS InputError verdict)" do
      assert ResultNormalization.interpret_result("No formulae and clauses found in input file") ==
               {:ok, :input_error}
    end

    test "SPASS \"Undefined symbol\" → {:ok, :input_error}" do
      assert ResultNormalization.interpret_result("Undefined symbol foo in line 3") ==
               {:ok, :input_error}
    end

    test "Waldmeister \"Unexpected end of file\" → {:ok, :input_error}" do
      assert ResultNormalization.interpret_result("****  Unexpected end of file.") ==
               {:ok, :input_error}
    end

    test "SPASS \"Please report this error\" stays in {:error, :internal_error}" do
      assert ResultNormalization.interpret_result("Please report this error to the SPASS team.") ==
               {:error, :internal_error}
    end

    test "Waldmeister SegFault stays in {:error, :internal_error}" do
      assert ResultNormalization.interpret_result("Unrecoverable Segmentation Fault") ==
               {:error, :internal_error}
    end

    test "Vampire SIGINT → :forced" do
      assert ResultNormalization.interpret_result("Aborted by signal SIGINT") ==
               {:ok, :forced}
    end

    test "Vampire Satisfiability detected → :satisfiable" do
      assert ResultNormalization.interpret_result("Satisfiability detected") ==
               {:ok, :satisfiable}
    end

    test "Alt-Ergo Valid → :theorem" do
      assert ResultNormalization.interpret_result("File foo.ae: Valid (0.01s)") ==
               {:ok, :theorem}
    end

    test "Alt-Ergo Unknown → :unknown (not :gave_up)" do
      assert ResultNormalization.interpret_result("File foo.ae: Unknown (0.01s)") ==
               {:ok, :unknown}
    end
  end
end
