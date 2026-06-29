defmodule AtpClient.IsabelleTheoryTest do
  use ExUnit.Case, async: true

  # Tests for the theory auto-wrapping that prove_theory/4 delegates to
  # IsabelleClient.Theory.source/3.

  alias AtpClient.Isabelle
  alias IsabelleClient.Theory

  describe "Theory.source/3 — wrapping" do
    test "passes a full theory through unchanged" do
      full = "theory Foo imports Main begin\nlemma p: True by auto\nend\n"
      assert Theory.source("Foo", full) == full
    end

    test "wraps bare text that lacks a theory header" do
      body = "lemma p: \"True\" by auto\n"
      result = Theory.source("Bar", body)
      assert String.starts_with?(result, "theory Bar imports Main begin\n")
      assert String.contains?(result, body)
      assert String.ends_with?(result, "end\n")
    end

    test "accepts a custom imports argument" do
      body = "lemma p: \"True\" by auto\n"
      result = Theory.source("Bar", body, "HOL-Analysis.Analysis")
      assert String.contains?(result, "imports HOL-Analysis.Analysis")
    end

    test "body that starts with whitespace before 'theory' is still treated as full" do
      full = "  theory Foo imports Main begin\nend\n"
      assert Theory.source("Foo", full) == full
    end
  end

  describe "Isabelle.lemma_specs/1" do
    test "returns [] for a body with no lemma declarations" do
      assert Isabelle.lemma_specs("axiomatization where p: \"True\"\n") == []
    end

    test "extracts a single lemma, range runs to end of body" do
      body = "lemma g: \"P ∨ ¬ P\"\n  by auto\n"
      assert Isabelle.lemma_specs(body) == [%{name: "g", range: 1..3}]
    end

    test "two lemmas — first range stops on the line before the second" do
      body = """
      lemma g1: "P"
        by auto

      lemma g2: "Q"
        by auto
      """

      assert Isabelle.lemma_specs(body) == [
               %{name: "g1", range: 1..3},
               %{name: "g2", range: 4..6}
             ]
    end

    test "preserves declaration order" do
      body = "lemma zeta: \"P\"\nlemma alpha: \"Q\"\n"

      assert Isabelle.lemma_specs(body) == [
               %{name: "zeta", range: 1..1},
               %{name: "alpha", range: 2..3}
             ]
    end

    test "ignores `lemma \"…\"` declarations that lack a name" do
      body = "lemma \"P ∨ ¬ P\" by auto\n"
      assert Isabelle.lemma_specs(body) == []
    end
  end
end
