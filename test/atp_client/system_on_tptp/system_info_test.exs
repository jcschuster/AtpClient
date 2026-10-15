defmodule AtpClient.SystemOnTptp.SystemInfoTest do
  use ExUnit.Case, async: true

  alias AtpClient.System
  alias AtpClient.SystemOnTptp.Audit
  alias AtpClient.SystemOnTptp.SystemInfo
  alias AtpClient.SystemOnTptp.Systems
  alias Tptp.Szs.Ontology

  doctest SystemInfo
  doctest System

  # The report of 2026-10-14; see test/fixtures/README.md.
  @report File.read!("test/fixtures/system_info_2026-10-14.txt")
  @overrides System.read_overrides("priv/system_on_tptp/overrides.json")

  setup_all do
    {:ok, systems, warnings} = SystemInfo.parse(@report)
    %{systems: systems, warnings: warnings, by_name: Map.new(systems, &{&1.name, &1})}
  end

  describe "parse/1 over the 2026-10-14 report" do
    test "all 174 records parse, with no warnings", %{systems: systems, warnings: warnings} do
      assert length(systems) == 174
      assert warnings == []
      assert systems |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 174
    end

    test "every Status word is an atom or kept in raw", %{systems: systems} do
      for system <- systems do
        assert Enum.all?(system.interfaces ++ system.listings, &is_atom/1)
        assert Enum.all?(system.raw.status, &is_binary/1)
      end

      assert systems |> Enum.flat_map(& &1.raw.status) |> Enum.frequencies() == %{"SCCPA" => 1}
    end

    test "every Solved and StartSoln word is an ontology value or kept in raw", %{
      systems: systems
    } do
      for system <- systems do
        assert Enum.all?(Map.keys(system.solved), &(&1 in Ontology.values()))
        assert Enum.all?(Map.keys(system.dataforms), &(&1 in Ontology.values()))

        for word <- Map.keys(system.raw.solved) ++ Map.keys(system.raw.dataforms) do
          assert Ontology.from_string(word) == :error
        end
      end

      assert systems |> Enum.flat_map(&Map.keys(&1.raw.solved)) |> Enum.uniq() |> Enum.sort() ==
               ~w(NotRated PartialSuccess Rated Verified)
    end

    test "the interface counts", %{systems: systems} do
      # The report has 92 SoTPTP words: one record (line 2416) lists SoTPTP twice.
      counts =
        for interface <- [
              :system_on_tptp,
              :system_b4_tptp,
              :system_on_tstp,
              :system_on_tmtp,
              :pre_tptp
            ],
            do: Enum.count(systems, &(interface in &1.interfaces))

      assert counts == [91, 29, 15, 2, 5]
    end

    test "a record read field by field", %{by_name: by_name} do
      e = by_name["E"]
      assert %System{id: "E---3.5.1", version: "3.5.1", people: ["Stephan Schulz"]} = e
      assert e.url == "http://www.eprover.org/"
      assert e.spcs == ~w(TH0_NAR TX0_NAR TF0_NAR FOF CNF)
      assert e.solved.theorem == "SZS status Theorem"
      assert e.dataforms.cnf_refutation == "SZS output start CNFRefutation"
      assert e.raw.end_soln["Saturation"] == "SZS output end Saturation"
      assert e.interfaces == [:system_on_tptp]
      assert e.listings == [:sscpa, :tstp, :starexec, :casc]
      assert e.statistic == nil

      agmv = by_name["AGMV"]
      assert agmv.people == ["Geoff Sutcliffe", "Alex Steen"]
      assert agmv.url == nil
      assert agmv.solved.verified_good == "SZS status Verified"
    end

    test "a record missing a field is a warning, not a failure" do
      assert {:ok, [%System{id: "X---1"}], [{:missing_fields, "X---1", missing}]} =
               SystemInfo.parse("X---1 =>\n    System == X\n")

      assert "Status" in missing
    end
  end

  describe "capabilities/2 over the 2026-10-14 report" do
    test "counts per capability, overrides applied", %{systems: systems} do
      caps = Enum.map(systems, &System.capabilities(&1, @overrides))

      counts =
        for capability <- System.all_capabilities(),
            into: %{},
            do: {capability, Enum.count(caps, &Map.has_key?(&1, capability))}

      assert counts == %{
               prove: 110,
               find_model: 41,
               verify: 13,
               verify_model: 2,
               transform: 24,
               check: 5,
               inspect: 10,
               import: 5
             }

      refute Enum.any?(caps, &(&1 == %{}))
    end

    test "the PreTPTP converters get :import by rule", %{systems: systems} do
      converters = for system <- systems, :pre_tptp in system.interfaces, do: system

      assert Enum.map(converters, & &1.name) ==
               ~w(ACE2TPTP DFG2TPTP LADR2TPTP Otter2TPTP SMT2TPTP)

      for system <- converters, do: assert(System.capabilities(system, %{})[:import] == :rule)
    end

    test "the rules by example", %{by_name: by_name} do
      assert System.capabilities(by_name["E"], %{}) == %{prove: :rule, find_model: :rule}
      assert System.capabilities(by_name["Mace4"], %{})[:find_model] == :rule
      assert System.capabilities(by_name["GDV"], %{}) == %{verify: :rule}
      assert System.capabilities(by_name["ECNF"], %{}) == %{transform: :rule}
      assert System.capabilities(by_name["BNFParser"], %{}) == %{check: :rule}
      # No rule gives :inspect; IDV's record is Success and nothing else.
      assert System.capabilities(by_name["IDV"], %{}) == %{inspect: :note}
      assert System.capabilities(by_name["Leo-III-STC"], %{}) == %{check: :rule}
      # TPTP4X is on three interfaces with every field NO INFORMATION: the
      # fallback, not a rule, is what classifies it.
      assert System.capabilities(by_name["TPTP4X"], %{}) == %{transform: :note}
      # AGMV's key is VerifiedGood, its pattern SZS status Verified.
      assert System.derived(by_name["AGMV"]) == %{verify: :rule, verify_model: :note}
    end

    test "the fallback fires for exactly the systems the audit lists", %{systems: systems} do
      fallback =
        for system <- systems,
            derived = System.derived(system),
            derived == %{} or Enum.any?(derived, &(elem(&1, 1) == :note)),
            do: system.name

      assert Enum.sort(fallback) ==
               Enum.sort(~w(CheckTyping GetSymbols ProblemStats SPCForProblem TPII TPTP2X AGMV
                            cvc5-STC Infinox SleighQueen Vampire-LP AGInTRater IDV IIV
                            ProofSummary PProofSummary ProofStats SolutionStats Taelja TSTP2NL
                            TPTP4X TPTP2JSON InterpretByATP))

      assert Enum.sort(fallback) == @overrides |> Map.keys() |> Enum.sort()
      assert systems |> Audit.findings(%{}) |> Enum.map(& &1.system) |> length() == 23
    end

    test "an override replaces the derived set", %{by_name: by_name} do
      assert System.capabilities(by_name["TPTP2X"], @overrides) == %{transform: :override}
      assert System.capabilities(by_name["TPTP2X"], %{}) == %{transform: :note}
    end
  end

  describe "dialects/1 over the 2026-10-14 report" do
    test "counts per dialect, every SPC word read", %{systems: systems} do
      dialects = Enum.map(systems, &System.dialects/1)

      counts =
        for dialect <- Tptp.Query.dialects(),
            into: %{},
            do: {dialect, Enum.count(dialects, &Keyword.has_key?(&1 || [], dialect))}

      assert counts == %{
               unknown: 0,
               cnf: 100,
               fof: 116,
               tcf: 0,
               tf0: 52,
               tf1: 18,
               tx0: 21,
               tx1: 7,
               th0: 31,
               th1: 14,
               dh0: 2,
               dh1: 2,
               nxf: 11,
               nhf: 7
             }

      assert Enum.count(dialects, &is_nil/1) == 29
      assert Enum.flat_map(systems, &System.unread_spcs/1) == []
    end

    test "the readings by example", %{by_name: by_name} do
      assert System.dialects(by_name["iProver"]) == [tf0: ["NDT"], fof: [], cnf: []]
      assert System.dialects(by_name["MiniSAT"]) == [cnf: ["PRP"], cnf: ["EPR"]]
      # NX1 and NX0 are both :nxf, and listed once.
      assert Keyword.get_values(System.dialects(by_name["Leo-III"]), :nxf) == [[]]
      # SPCForProblem names families: NTF THF TXF TFF FOF CNF.
      assert System.dialects(by_name["SPCForProblem"]) ==
               [
                 nxf: [],
                 nhf: [],
                 th0: [],
                 th1: [],
                 tx0: [],
                 tx1: [],
                 tf0: [],
                 tf1: [],
                 fof: [],
                 cnf: []
               ]

      assert System.dialects(by_name["TPTP4X"]) == nil
    end
  end

  describe "Audit.findings/3" do
    test "the committed overrides silence the 2026-10-14 report", %{systems: systems} do
      assert Audit.findings(systems, @overrides, systems) == []
    end

    test "a stale and an unadvertised override", %{systems: systems} do
      overrides =
        Map.merge(@overrides, %{
          "E" => %{capabilities: [:prove], reason: "r", since: "2026-10-14"},
          "Gone" => %{capabilities: [:prove], reason: "r", since: "2026-10-14"}
        })

      assert [
               %{system: "E", finding: :stale_override},
               %{system: "Gone", finding: :unadvertised_override}
             ] =
               Audit.findings(systems, overrides)
    end

    test "a word seen for the first time", %{systems: systems} do
      # CSE_E is the one record with the Status word SCCPA.
      previous = Enum.reject(systems, &(&1.name == "CSE_E"))

      assert [%{system: "CSE_E---1.7", finding: {:new_word, :status, "SCCPA"}}] =
               Audit.findings(systems, @overrides, previous)
    end

    test "an SPC word of no known form", %{by_name: by_name} do
      e = %{by_name["E"] | spcs: ~w(TC0_NAR FOF CNF)}

      assert [%{system: "E---3.5.1", finding: {:unread_spc, "TC0_NAR"}} = line] =
               Audit.findings([e], %{})

      assert Audit.format([line]) =~ ~s(SPC word "TC0_NAR")
    end

    test "each line names the override that would silence it", %{systems: systems} do
      [line | _] = Audit.findings(systems, %{})
      assert line.suggestion =~ ~s("capabilities")
      assert Audit.format([line]) =~ line.system
    end
  end

  describe "snapshot" do
    test "to_json/1 and from_json/1 round-trip every record", %{systems: systems} do
      for system <- systems do
        assert system
               |> System.to_json()
               |> Jason.encode!()
               |> Jason.decode!()
               |> System.from_json() ==
                 system
      end
    end

    test "the encoded snapshot reads back", %{systems: systems} do
      state = %{systems: systems, generated_at: ~U[2026-10-14 00:00:00Z], source: "x"}

      path =
        Path.join(
          Elixir.System.tmp_dir!(),
          "atp_client_snapshot_#{:erlang.unique_integer([:positive])}.json"
        )

      File.write!(path, Systems.encode_snapshot(state))
      on_exit(fn -> File.rm(path) end)

      read = Systems.read_snapshot(path)
      assert read.generated_at == ~U[2026-10-14 00:00:00Z]
      assert Enum.sort_by(read.systems, & &1.id) == Enum.sort_by(systems, & &1.id)
    end

    test "the shipped snapshot loads", %{} do
      %{systems: systems, generated_at: %DateTime{}, source: source} =
        Systems.read_snapshot("priv/system_on_tptp/systems.json")

      assert length(systems) > 100
      assert source =~ "tptp.org"
    end

    test "delta/2" do
      a = %System{id: "A---1", name: "A"}
      b = %System{id: "B---1", name: "B"}
      assert Systems.delta([a], [a, %{b | note: "x"}]) == "+B---1, 0 fields changed"
      assert Systems.delta([a, b], [%{a | note: "x"}]) == "−B---1, 1 field changed"
    end
  end
end
