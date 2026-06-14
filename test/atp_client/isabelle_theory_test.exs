defmodule AtpClient.IsabelleTheoryTest do
  use ExUnit.Case, async: true

  # Tests for the theory auto-wrapping that prove_theory/4 delegates to
  # IsabelleClient.Theory.source/3.

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
end
