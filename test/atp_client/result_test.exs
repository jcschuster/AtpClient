defmodule AtpClient.ResultTest do
  use ExUnit.Case, async: true

  alias AtpClient.Result
  alias AtpClient.Verdict

  doctest Result

  @derivation """
  % SZS status Theorem for x
  % SZS output start CNFRefutation for x
  fof(a, axiom, p, file('x', a)).
  fof(c, plain, p, inference(cnf_transformation, [status(thm)], [a])).
  % SZS output end CNFRefutation for x
  """

  describe "proof/1" do
    test "reads the first proof-family block as TPTP, with the derivation intact" do
      {:ok, result} = Verdict.interpret(@derivation, AtpClient.LocalExec)

      assert {:ok, %Tptp.File{} = proof, []} = Result.proof(result)
      assert [a, c] = proof.statements
      assert a.name.text == "a"
      assert c.source != nil
      assert Tptp.Statement.text(c, proof.source) =~ "inference(cnf_transformation"
    end

    test "is :none without such a block" do
      {:ok, result} = Verdict.interpret("% SZS status Theorem for x\n", AtpClient.LocalExec)
      assert Result.proof(result) == :none

      output =
        "% SZS status Satisfiable for x\n% SZS output start FiniteModel for x\nfof(m, fi_domain, $true).\n% SZS output end FiniteModel for x\n"

      {:ok, result} = Verdict.interpret(output, AtpClient.LocalExec)
      assert [%{dataform: :finite_model}] = result.blocks
      assert Result.proof(result) == :none
    end
  end

  test "success?/1 follows the ontology" do
    {:ok, theorem} = Verdict.interpret("% SZS status Theorem for x", AtpClient.LocalExec)
    {:ok, gave_up} = Verdict.interpret("% SZS status GaveUp for x", AtpClient.LocalExec)
    assert Result.success?(theorem)
    refute Result.success?(gave_up)
  end
end
