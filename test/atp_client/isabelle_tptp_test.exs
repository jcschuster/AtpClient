defmodule AtpClient.IsabelleTptpTest do
  use ExUnit.Case, async: true

  # Offline coverage for AtpClient.Isabelle.query_tptp/2 and prove_tptp/3.
  # The end-to-end path requires a live Isabelle server; the assertions here
  # pin the dep-side contracts we rely on and the option-routing seam.

  alias IsabelleClient.TPTP

  describe "IsabelleClient.TPTP — dep contract" do
    test "source_path/0 points at a readable TPTP.thy" do
      path = TPTP.source_path()
      assert File.regular?(path)
      assert Path.basename(path) == "TPTP.thy"
    end

    test "isabellize_theory/1 maps thf/conjecture to a lemma command carrying the formula name" do
      output = TPTP.isabellize_theory(~S"thf(g1, conjecture, ! [X: $i]: (p @ X | ~ (p @ X))).")

      assert output =~ "lemma g1"
    end

    test "isabellize_theory/1 maps thf/axiom to an axiomatization command" do
      output = TPTP.isabellize_theory(~S"thf(a1, axiom, ! [X: $i]: p @ X).")

      assert output =~ "axiomatization where a1"
    end

    test "isabellize_theory/1 maps thf/type with $tType to typedecl" do
      output = TPTP.isabellize_theory(~S"thf(i_type, type, i: $tType).")

      assert output =~ "typedecl i"
    end
  end

  describe "AtpClient.Isabelle.query_tptp/2 — wiring" do
    test "routes through open_session so missing required config surfaces as ArgumentError" do
      # :password has no default in mix.exs and is fetched by open_session/1
      # before any TPTP-specific work runs. This pins query_tptp as a peer of
      # query_lemmas (which fails the same way for the same reason).
      assert_raise ArgumentError, ~r/missing required setting `:password`/, fn ->
        AtpClient.Isabelle.query_tptp(~S"thf(g, conjecture, $true).")
      end
    end
  end
end
