defmodule AtpClient.SystemOnTptp.ReplyTest do
  use ExUnit.Case, async: true

  alias AtpClient.Result
  alias AtpClient.SystemOnTptp
  alias AtpClient.SystemOnTptp.Reply

  doctest Reply

  defp fixture(name), do: File.read!(Path.join("test/fixtures", name))

  defp read(name) do
    for {id, text} <- Reply.sections(fixture(name)), do: {id, SystemOnTptp.read_section(id, text)}
  end

  describe "sections/1, TSTP shape" do
    test "one section per solution file, named by its File key" do
      assert [{"E---3.5.1", e}, {"Vampire---5.0.1", vampire}] =
               Reply.sections(fixture("sotp_x2tptp_e_vampire.txt"))

      assert e =~ ~r/\A%-+\n% File     : E---3.5.1\n/
      assert vampire =~ ~r/\A%-+\n% File     : Vampire---5.0.1\n/
      assert e <> vampire == fixture("sotp_x2tptp_e_vampire.txt")
    end

    test "a system that did not run has no section" do
      assert [{"Twee---2.7", _}] = Reply.sections(fixture("sotp_x2tptp_inappropriate.txt"))
    end
  end

  describe "sections/1, raw shape" do
    test "the delimited output and the summary lines, named by % RESULT:" do
      assert [{"E---3.5.1", e}, {"Vampire---5.0.1", vampire}] =
               Reply.sections(fixture("sotp_raw_e_vampire.txt"))

      assert e =~ ~r/\A% START OF SYSTEM OUTPUT\n/
      assert e =~ ~r/% OUTPUT: \S+ - E---3.5.1 says CNFRefutation[^\n]*\n\z/
      assert vampire =~ ~r/% RESULT: \S+ - Vampire---5.0.1 says Theorem/
    end

    test "the five-system model reply keeps the order of the form" do
      assert ~w(Mace4---2026-6A Paradox---4.0 Vampire-SAT---5.0.1 E-SAT---3.5.1 cvc5-SAT---1.3.4) ==
               fixture("sotp_raw_models.txt") |> Reply.sections() |> Enum.map(&elem(&1, 0))
    end

    test "a system that did not run is its summary lines alone" do
      assert [{"Satallax---3.5", satallax}, {"Twee---2.7", _}] =
               Reply.sections(fixture("sotp_raw_inappropriate.txt"))

      refute satallax =~ "START OF SYSTEM OUTPUT"
      assert satallax =~ "says Inappropriate"
    end

    test "% RESULT: lines a system prints itself stay in its section" do
      assert [{"GDV---2.0", gdv}] = Reply.sections(fixture("gdv_verified_good.txt"))
      assert gdv =~ "E---3.5.1 says Theorem"
    end
  end

  describe "read_section/2" do
    test "TSTP: status from the archived output, the solution under details.tstp" do
      assert [{"E---3.5.1", {:ok, e}}, {"Vampire---5.0.1", {:ok, vampire}}] =
               read("sotp_x2tptp_e_vampire.txt")

      assert %Result{status: :theorem, evidence: :szs, system: "E---3.5.1"} = e
      assert %Tptp.Tstp.Solution{output: :cnf_refutation} = e.details.tstp
      assert e.output =~ "% File     : E---3.5.1"
      assert vampire.status == :theorem

      assert {:ok, derivation, []} = Result.derivation(e)
      assert length(derivation.order) == 11
      assert ["c_0_10"] = derivation.roots
    end

    test "TSTP: with no derivation region the proof block in the original output is read" do
      # Twee's proof is prose ("Axiom 1 (...): ..."), which X2TPTP could not convert
      # and which does not parse as TPTP.
      assert [{"Twee---2.7", {:ok, twee}}] = read("sotp_x2tptp_inappropriate.txt")
      assert twee.status == :theorem
      assert twee.details.tstp.solution == nil
      assert [%{dataform: :proof}] = twee.blocks

      assert {:error, {:invalid_derivation, [%Tptp.Diagnostic{severity: :error} | _]}} =
               Result.derivation(twee)
    end

    test "TSTP: the header's Result when the archived output holds no status" do
      rule = "%" <> String.duplicate("-", 78) <> "\n"

      text =
        rule <>
          "% File     : Otter---3.3\n% Result   : Unsatisfiable 0.1s\n% Output   : Refutation\n" <>
          rule <>
          "cnf(c, plain, $false).\n" <>
          rule <> "%----ORIGINAL SYSTEM OUTPUT\n% nothing here\n" <> rule

      assert {:ok, %Result{status: :unsatisfiable, evidence: {:tstp, "Result"}} = result} =
               SystemOnTptp.read_section("Otter---3.3", text)

      assert result.output == text
      assert {:ok, %Tptp.Derivation{order: ["c"]}, _} = Result.derivation(result)
    end

    test "raw: read as it is, blocks from the section" do
      assert [{"E---3.5.1", {:ok, e}}, {"Vampire---5.0.1", {:ok, vampire}}] =
               read("sotp_raw_e_vampire.txt")

      assert e.status == :theorem and e.details == %{}
      assert [%{dataform: :cnf_refutation}] = e.blocks
      assert [%{dataform: :proof}] = vampire.blocks
      assert {:ok, %Tptp.Derivation{}, _} = Result.derivation(vampire)
    end

    test "raw: a system that did not run reads its summary line" do
      assert [{"Satallax---3.5", {:ok, satallax}}, _] = read("sotp_raw_inappropriate.txt")
      assert satallax.status == :inappropriate
      assert {:pattern, "% RESULT: " <> _} = satallax.evidence
    end

    test "raw: the model systems" do
      outcomes = Map.new(read("sotp_raw_models.txt"))

      for {id, {:ok, result}} <- outcomes, do: assert(result.status == :satisfiable, id)

      assert [%{dataform: :finite_model}] = elem(outcomes["Paradox---4.0"], 1).blocks
      assert [%{dataform: :saturation}] = elem(outcomes["E-SAT---3.5.1"], 1).blocks
    end
  end

  describe "formulae/1" do
    test "a ListOfCNF block, read as ListOfFormulae; its inner status line is not the verdict" do
      assert [{"ECNF---3.5.1", {:ok, result}}] = read("ecnf_process_problem.txt")
      assert result.status == :success
      assert {:ok, %Tptp.File{statements: statements}, []} = Result.formulae(result)
      assert length(statements) == 3
    end

    test ":none without one" do
      [{_, {:ok, result}} | _] = read("sotp_raw_e_vampire.txt")
      assert Result.formulae(result) == :none
    end
  end
end
