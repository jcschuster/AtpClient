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
  # per_lemma_results/2
  # ──────────────────────────────────────────────────────────────────────────

  defp msg_at(text, line, kind \\ "writeln"),
    do: %{"kind" => kind, "message" => text, "pos" => %{"line" => line}}

  describe "per_lemma_results/2 — basic cases" do
    test "empty payload returns empty list" do
      assert ResultNormalization.per_lemma_results(%{"nodes" => [], "ok" => true}) == []
    end

    test "single named proved lemma" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 2)])])
      assert ResultNormalization.per_lemma_results(p) == [
               %{line: 2, name: "foo", result: {:ok, :thm}}
             ]
    end

    test "single anonymous proved lemma" do
      p = payload([theory_node([msg_at("theorem:\n  True", 2)])])
      assert ResultNormalization.per_lemma_results(p) == [
               %{line: 2, name: nil, result: {:ok, :thm}}
             ]
    end

    test "multiple lemmas sorted by line" do
      p =
        payload([
          theory_node([
            msg_at("theorem bar:\n  Q", 5),
            msg_at("theorem foo:\n  P", 2)
          ])
        ])

      assert ResultNormalization.per_lemma_results(p) == [
               %{line: 2, name: "foo", result: {:ok, :thm}},
               %{line: 5, name: "bar", result: {:ok, :thm}}
             ]
    end

    test "failed lemma (error message, no theorem)" do
      p = payload([theory_node([msg_at("Failed to finish proof", 3, "error")])])
      assert ResultNormalization.per_lemma_results(p) == [
               %{line: 3, name: nil, result: {:ok, :gave_up}}
             ]
    end

    test "mixed: some proved, some failed" do
      p =
        payload([
          theory_node([
            msg_at("theorem foo:\n  P", 2),
            msg_at("Failed to finish proof", 5, "error")
          ])
        ])

      assert ResultNormalization.per_lemma_results(p) == [
               %{line: 2, name: "foo", result: {:ok, :thm}},
               %{line: 5, name: nil, result: {:ok, :gave_up}}
             ]
    end

    test "error at the same line as a theorem completion is not double-reported" do
      p =
        payload([
          theory_node([
            msg_at("theorem foo:\n  P", 2),
            msg_at("some error", 2, "error")
          ])
        ])

      assert ResultNormalization.per_lemma_results(p) == [
               %{line: 2, name: "foo", result: {:ok, :thm}}
             ]
    end

    test "duplicate errors at the same line produce one entry" do
      p =
        payload([
          theory_node([
            msg_at("Failed", 4, "error"),
            msg_at("Also failed", 4, "error")
          ])
        ])

      assert length(ResultNormalization.per_lemma_results(p)) == 1
    end
  end

  describe "per_lemma_results/2 — line_offset option" do
    test "subtracts offset from all reported lines" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 3)])])

      assert ResultNormalization.per_lemma_results(p, line_offset: 1) == [
               %{line: 2, name: "foo", result: {:ok, :thm}}
             ]
    end

    test "offset 0 leaves lines unchanged" do
      p = payload([theory_node([msg_at("theorem foo:\n  P", 2)])])
      assert ResultNormalization.per_lemma_results(p, line_offset: 0) == [
               %{line: 2, name: "foo", result: {:ok, :thm}}
             ]
    end

    test "nil position survives offset unchanged" do
      p = payload([theory_node([msg("theorem foo:\n  P")])])
      [entry] = ResultNormalization.per_lemma_results(p, line_offset: 1)
      assert entry.line == nil
    end
  end
end
