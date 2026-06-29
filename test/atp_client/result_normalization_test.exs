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
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :thm}
    end

    test "recognizes proof-completion message for an anonymous lemma" do
      p = payload([theory_node([msg("theorem:\n  True")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :thm}
    end

    test "recognizes theorem message that is not the first message" do
      p = payload([theory_node([msg("Auto Quickcheck found no counterexample"), msg("theorem foo:\n  P")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :thm}
    end

    test "recognizes multiple theorem messages (multi-lemma theory)" do
      p = payload([theory_node([msg("theorem foo:\n  P"), msg("theorem bar:\n  Q")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :thm}
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
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :thm}
    end

    test "Nitpick found a counterexample → :csat" do
      p = payload([theory_node([msg("Nitpick found a counterexample")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :csat}
    end

    test "Nitpick found a model → :sat" do
      p = payload([theory_node([msg("Nitpick found a model")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :sat}
    end

    test "Nitpick found no counterexample without a theorem message → :gave_up" do
      p = payload([theory_node([msg("Nitpick found no counterexample")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :gave_up}
    end

    test "timed out → :timeout" do
      p = payload([theory_node([msg("Sledgehammer: timed out")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :timeout}
    end

    test "Out of memory → :out_of_resources" do
      p = payload([theory_node([msg("Out of memory")])])
      assert ResultNormalization.interpret_isabelle_result(p) == {:ok, :out_of_resources}
    end
  end

  describe "interpret_isabelle_result/1 — no false positives" do
    test "message containing 'theorem' mid-sentence does not trigger :thm" do
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
               %{name: "foo", result: {:ok, :thm}}
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
               %{name: "foo", result: {:ok, :thm}},
               %{name: "bar", result: {:ok, :thm}}
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
               %{name: "g", result: {:ok, :csat}}
             ]
    end

    test "'found a proof' beats 'Nitpick found a model' (sat) in the same bucket" do
      p =
        payload([
          theory_node([
            msg_at("Sledgehammer: found a proof", 3),
            msg_at("Nitpick found a model", 3)
          ])
        ])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :thm}}
             ]
    end

    test "Nitpick model classifies as :sat" do
      p = payload([theory_node([msg_at("Nitpick found a model", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :sat}}
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

    test "theorem completion without a failure error counts as :thm" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("foo", 3..3)]) == [
               %{name: "foo", result: {:ok, :thm}}
             ]
    end

    test "timed out signal classifies as :timeout" do
      p = payload([theory_node([msg_at("Sledgehammer: timed out", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :timeout}}
             ]
    end

    test "Out of memory classifies as :out_of_resources" do
      p = payload([theory_node([msg_at("Out of memory", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :out_of_resources}}
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
    test "Nitpick model + Nitpick found no counterexample → :sat, not :csat" do
      # The pre-fix classifier concatenated both messages and ran the
      # `"Nitpick found a" + "counterexample"` substring test across the
      # join, producing a spurious `:csat`. Now each message is scanned
      # individually, so the model wins.
      p =
        payload([
          theory_node([
            msg_at("Nitpick found a model", 3),
            msg_at("Nitpick found no counterexample", 3)
          ])
        ])

      assert ResultNormalization.per_lemma_results(p, [spec("g", 3..3)]) == [
               %{name: "g", result: {:ok, :sat}}
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
               %{name: "g1", result: {:ok, :thm}},
               %{name: "g2", result: {:ok, :csat}},
               %{name: "g3", result: {:ok, :thm}}
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
               %{name: "g1", result: {:ok, :thm}},
               %{name: "g2", result: {:ok, :thm}}
             ]
    end
  end

  describe "per_lemma_results/3 — :line_offset option" do
    test "subtracts offset before bucketing" do
      # Body line 2 lands at on-disk line 3 after auto-wrap (+1 header line).
      p = payload([theory_node([msg_at("theorem foo:\n  P", 3)])])

      assert ResultNormalization.per_lemma_results(p, [spec("foo", 2..2)], line_offset: 1) == [
               %{name: "foo", result: {:ok, :thm}}
             ]
    end

    test "offset 0 leaves lines unchanged" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 2)])])

      assert ResultNormalization.per_lemma_results(p, [spec("foo", 2..2)], line_offset: 0) == [
               %{name: "foo", result: {:ok, :thm}}
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
             ) == [%{name: "foo", result: {:ok, :thm}}]
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
               %{name: "foo", result: {:ok, :thm}}
             ]
    end
  end
end
