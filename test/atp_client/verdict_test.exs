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
      for {_text, verdict} <- Verdict.patterns(nil) do
        case verdict do
          {:ok, value} ->
            assert Ontology.success?(value) or Ontology.no_success?(value)

          {:error, reason} ->
            assert reason == :internal_error
        end
      end
    end
  end

  describe "prover-specific patterns are read for their own system" do
    @transform_error "ERROR: Formatter did not create all the E---3.5.1 format files\n" <>
                       "ERROR: Unknown procedure: definitely_not_a_real_transform/6\n"

    test "Alt-Ergo's `: Unknown` is not read in a SystemOnTPTP error for E" do
      assert Verdict.interpret(@transform_error, AtpClient.SystemOnTptp, system: "E---3.5.1") ==
               {:error, {:unrecognized_output, @transform_error}}

      assert {:ok, %Result{status: :unknown, evidence: {:pattern, ": Unknown"}}} =
               Verdict.interpret("File foo.ae: Unknown (0.01s)", AtpClient.SystemOnTptp,
                 system: "Alt-Ergo---2.6.2"
               )
    end

    test "a system is matched by SystemOnTPTP name, identifier or LocalExec binary" do
      timeout = "Failure: Resource limit exceeded (time)"

      for system <- ["E", "E---3.5.1", "E-SAT---3.5.1", "eprover", "/usr/bin/eprover-ho"] do
        assert {:ok, %Result{status: :timeout}} =
                 Verdict.interpret(timeout, AtpClient.LocalExec, system: system)
      end

      for system <- ["E-Darwin---1.5", "Vampire---5.0.1", "my_wrapper.sh"] do
        assert {:error, {:unrecognized_output, _}} =
                 Verdict.interpret(timeout, AtpClient.LocalExec, system: system)
      end
    end

    test "`:system_name` names the system where `:system` does not" do
      assert {:ok, %Result{status: :timeout, system: "my_wrapper.sh"}} =
               Verdict.interpret("Time limit reached!", AtpClient.LocalExec,
                 system: "my_wrapper.sh",
                 system_name: "Vampire"
               )

      # StarExec without `:system`: a configuration id, so every group is read.
      assert {:ok, %Result{status: :timeout}} =
               Verdict.interpret("Time limit reached!", AtpClient.StarExec,
                 system: "42",
                 system_name: nil
               )
    end

    test "no system at all reads every group" do
      assert status("File foo.ae: Valid (0.01s)") == {:ok, :theorem}
      assert status("Time limit reached!") == {:ok, :timeout}
    end

    test "every name in the table is a system in the shipped snapshot" do
      %{systems: [_ | _] = systems} =
        AtpClient.SystemOnTptp.Systems.read_snapshot(
          AtpClient.SystemOnTptp.Systems.snapshot_path()
        )

      names = MapSet.new(systems, & &1.name)

      for group <- Verdict.patterns(), name <- group.names do
        assert name in names, "#{name} is not advertised by SystemOnTPTP"
      end
    end

    test "a message is claimed by one group only" do
      texts = for group <- Verdict.patterns(), {text, _} <- group.patterns, do: text
      assert texts == Enum.uniq(texts)
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

  describe "0.8 readings" do
    test "a status line inside an output block is data, not the verdict" do
      output = File.read!("test/fixtures/ecnf_process_problem.txt")

      assert {:ok, %{status: :success, evidence: :szs}} =
               Verdict.interpret(output, AtpClient.SystemOnTptp)
    end

    test "the % RESULT: summary wins over a system's own says lines" do
      output =
        "% START OF SYSTEM OUTPUT\nBNFParser---0.0 says Success\n% END OF SYSTEM OUTPUT\n" <>
          "% RESULT: x - GDV---2.0 says VerifiedBad - CPU = 0\n% OUTPUT: x - GDV---2.0 says None\n"

      assert {:ok,
              %{
                status: :verified_bad,
                evidence: {:pattern, "% RESULT: x - GDV---2.0 says VerifiedBad"}
              }} =
               Verdict.interpret(output, AtpClient.SystemOnTptp)
    end

    @agmv %{verified_good: "SZS status Verified", verified_bad: "SZS status VerifiedBad"}

    test "a word outside the ontology is read through the system's Solved patterns" do
      assert {:error, {:unknown_szs_status, "Verified"}} =
               Verdict.interpret("% SZS status Verified\n", AtpClient.LocalExec)

      assert {:ok, %{status: :verified_good, evidence: {:system_info, "VerifiedGood"}}} =
               Verdict.interpret("% SZS status Verified\n", AtpClient.LocalExec, solved: @agmv)
    end

    test "a pattern is not found inside a longer word" do
      assert {:ok, %{status: :verified_bad, evidence: :szs}} =
               Verdict.interpret("% SZS status VerifiedBad\n", AtpClient.LocalExec, solved: @agmv)
    end

    test "Solved patterns with no SZS line at all, before the hand-written table" do
      solved = %{verified_good: "successfully checked", verified_bad: "ERROR CODE"}

      assert {:ok, %{status: :verified_good, evidence: {:system_info, "VerifiedGood"}}} =
               Verdict.interpret("[dedukti] File successfully checked\n", AtpClient.LocalExec,
                 solved: solved
               )

      assert {:ok, %{status: :gave_up, evidence: {:system_info, "GaveUp"}}} =
               Verdict.interpret("Time limit reached! gave up\n", AtpClient.LocalExec,
                 gave_up: ["gave up"]
               )
    end

    test ":prefix is removed from block bodies and is not put on the result" do
      output = File.read!("test/fixtures/starexec_stdout_thm.txt")

      {:ok, plain} = Verdict.interpret(output, AtpClient.StarExec)

      {:ok, stripped} =
        Verdict.interpret(output, AtpClient.StarExec, prefix: [Tptp.Szs.prefix(:starexec)])

      for %{body: body} <- stripped.blocks, do: refute(body =~ ~r/^\d+\.\d+\/\d+\.\d+/m)
      assert length(plain.blocks) == length(stripped.blocks)
    end
  end
end
