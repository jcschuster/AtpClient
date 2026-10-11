defmodule AtpClient.VerdictTest do
  use ExUnit.Case, async: true

  alias AtpClient.Result
  alias AtpClient.Verdict
  alias Tptp.Szs.Ontology

  doctest Verdict

  defp status(output) do
    case Verdict.interpret(output, AtpClient.LocalExec) do
      {:ok, %Result{status: status}} -> {:ok, status}
      {:error, _} = error -> error
    end
  end

  describe "the SZS status line" do
    test "Theorem and Unsatisfiable are kept distinct" do
      assert status("% SZS status Theorem for x") == {:ok, :theorem}
      assert status("% SZS status Unsatisfiable for x") == {:ok, :unsatisfiable}
    end

    test "Satisfiable and CounterSatisfiable are kept distinct" do
      assert status("% SZS status Satisfiable for x") == {:ok, :satisfiable}
      assert status("% SZS status CounterSatisfiable for x") == {:ok, :counter_satisfiable}
    end

    test "no-success values are results, under their SZS names" do
      for {word, value} <- [
            {"GaveUp", :gave_up},
            {"Unknown", :unknown},
            {"Incomplete", :incomplete},
            {"Timeout", :timeout},
            {"ResourceOut", :resource_out},
            {"MemoryOut", :memory_out},
            {"Forced", :forced},
            {"User", :user},
            {"Inappropriate", :inappropriate},
            {"Error", :error},
            {"InputError", :input_error}
          ] do
        assert status("% SZS status #{word} for x") == {:ok, value}
      end
    end

    test "the less common success values arrive under their ontology names" do
      for {word, value} <- [
            {"ContradictoryAxioms", :contradictory_axioms},
            {"Tautology", :tautology},
            {"TautologousConclusion", :tautologous_conclusion},
            {"WeakerConclusion", :weaker_conclusion},
            {"Equivalent", :equivalent},
            {"CounterEquivalent", :counter_equivalent},
            {"CounterTheorem", :counter_theorem},
            {"EquivalentCounterTheorem", :equivalent_counter_theorem},
            {"EquiSatisfiable", :equi_satisfiable},
            {"NoConsequence", :no_consequence},
            {"EquivalentTheorem", :equivalent_theorem},
            {"FiniteTheorem", :finite_theorem}
          ] do
        assert status("% SZS status #{word} for x") == {:ok, value}
      end
    end

    test "a value is matched whole, never as a prefix of a longer one" do
      assert status("% SZS status ContradictoryAxioms for x") == {:ok, :contradictory_axioms}
      assert status("% SZS status CounterSatisfiable for x") == {:ok, :counter_satisfiable}
      assert status("% SZS status InputError for x") == {:ok, :input_error}
    end

    test "E's framing: `#`, no `for`" do
      assert {:ok, %Result{status: :theorem, problem: nil}} =
               Verdict.interpret("# Proof found!\n# SZS status Theorem\n", AtpClient.LocalExec)
    end

    test "StarExec's framing: an elapsed-time prefix on every line" do
      output = File.read!("test/fixtures/starexec_stdout_thm.txt")
      assert status(output) == {:ok, :theorem}

      output = File.read!("test/fixtures/starexec_stdout_csat.txt")
      assert status(output) == {:ok, :counter_satisfiable}
    end

    test "the problem and the comment are carried" do
      assert {:ok, %Result{problem: "PUZ001+1", comment: "ran out of strategies"}} =
               Verdict.interpret(
                 "% SZS status GaveUp for PUZ001+1 : ran out of strategies",
                 AtpClient.LocalExec
               )
    end

    test "the last status line is the system's answer" do
      output = "% SZS status Theorem for x\n% SZS status GaveUp for x\n"
      assert status(output) == {:ok, :gave_up}
    end

    test "a word outside the ontology is reported, never made an atom" do
      assert status("% SZS status FiniteTheorems for x") ==
               {:error, {:unknown_szs_status, "FiniteTheorems"}}

      refute Enum.any?(Ontology.values(), &(Atom.to_string(&1) == "finite_theorems"))
    end

    test "a data value on a status line is not a status" do
      assert status("% SZS status Proof for x") == {:error, {:not_a_status, :proof}}
    end

    test "a lowercase word is not a status line" do
      assert status("SZS status theorem garbage") ==
               {:error, {:unrecognized_output, "SZS status theorem garbage"}}
    end
  end

  describe "the SystemOnTPTP summary line" do
    test "`says` is read when no status line is present" do
      assert {:ok, %Result{status: :finite_theorem, evidence: {:pattern, "says FiniteTheorem"}}} =
               Verdict.interpret(
                 "FooProver says FiniteTheorem for problem",
                 AtpClient.SystemOnTptp
               )
    end

    test "a status line wins over the summary" do
      output = "% SZS status Theorem for x\n% RESULT: x - Foo says GaveUp - CPU = 1\n"
      assert status(output) == {:ok, :theorem}
    end
  end

  describe "prover-specific patterns" do
    test "an SZS line wins over any pattern" do
      output = "% SZS status Theorem for p\n% SZS output start CNFRefutation\n..."
      assert status(output) == {:ok, :theorem}

      output = "% SZS status CounterSatisfiable for p\n...Termination reason: Satisfiable"
      assert status(output) == {:ok, :counter_satisfiable}
    end

    test "the matched pattern is the evidence" do
      assert {:ok,
              %Result{status: :gave_up, evidence: {:pattern, "SPASS beiseite: Completion found"}}} =
               Verdict.interpret("SPASS beiseite: Completion found", AtpClient.LocalExec)
    end

    test "SPASS" do
      assert status("SPASS beiseite: Completion found") == {:ok, :gave_up}
      assert status("No formulae and clauses found in input file") == {:ok, :input_error}
      assert status("Undefined symbol foo in line 3") == {:ok, :input_error}
      assert status("Please report this error to the SPASS team.") == {:error, :internal_error}
    end

    test "Vampire" do
      assert status("Aborted by signal SIGINT") == {:ok, :forced}
      assert status("Satisfiability detected") == {:ok, :gave_up}
      assert status("Termination reason: Satisfiable") == {:ok, :gave_up}
      assert status("Time limit reached!") == {:ok, :timeout}
    end

    test "Waldmeister" do
      assert status("****  Unexpected end of file.") == {:ok, :inappropriate}
      assert status("Unrecoverable Segmentation Fault") == {:error, :internal_error}
    end

    test "Alt-Ergo" do
      assert status("File foo.ae: Valid (0.01s)") == {:ok, :theorem}
      assert status("File foo.ae: Unknown (0.01s)") == {:ok, :unknown}
      assert status("I don't know") == {:ok, :gave_up}
    end

    test "E" do
      assert status("Failure: Resource limit exceeded (memory)") == {:ok, :memory_out}
      assert status("Failure: Resource limit exceeded (time)") == {:ok, :timeout}
    end

    test "every pattern maps to a status value or a crash" do
      for {_text, verdict} <- Verdict.patterns() do
        case verdict do
          {:ok, value} ->
            assert Ontology.success?(value) or Ontology.no_success?(value)

          {:error, reason} ->
            assert reason == :internal_error
        end
      end
    end
  end

  describe "the result" do
    test "carries the output, the backend and the fields given" do
      assert {:ok,
              %Result{
                output: "# SZS status Theorem\n",
                backend: AtpClient.LocalExec,
                system: "eprover"
              }} =
               Verdict.interpret("# SZS status Theorem\n", AtpClient.LocalExec, system: "eprover")
    end

    test "carries the delimited output blocks" do
      output = """
      % SZS status Unsatisfiable for GRP001-1
      % SZS output start CNFRefutation for GRP001-1
      cnf(1, axiom, p).
      % SZS output end CNFRefutation for GRP001-1
      """

      assert {:ok, %Result{blocks: [%{dataform: :cnf_refutation, body: "cnf(1, axiom, p)."}]}} =
               Verdict.interpret(output, AtpClient.LocalExec)
    end

    test "nothing readable is the whole output back" do
      assert status("nothing helpful here") ==
               {:error, {:unrecognized_output, "nothing helpful here"}}
    end
  end
end
