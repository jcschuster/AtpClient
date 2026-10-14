defmodule AtpClient.InterpretationTest do
  use ExUnit.Case, async: true

  alias AtpClient.Interpretation
  alias AtpClient.Interpretation.Standard
  alias AtpClient.Isabelle.Nitpick
  alias AtpClient.Result
  alias AtpClient.SystemOnTptp

  doctest Interpretation
  doctest Nitpick

  defp result(name) do
    [{id, text} | _] = SystemOnTptp.Reply.sections(File.read!(Path.join("test/fixtures", name)))
    {:ok, result} = SystemOnTptp.read_section(id, text)
    result
  end

  defp model(name) do
    {:ok, model, _diagnostics} = name |> result() |> Result.interpretation()
    model
  end

  defp tables(model),
    do: Map.take(model, [:kind, :domains, :constants, :functions, :predicates, :defaults])

  # The three fixtures are models of the same problem: p(a), ~p(f(a)), q symmetric,
  # q(a, f(a)), a != b.
  describe "the readers, by what the file contains" do
    test "Standard: the Mace4 2026-6A reply" do
      model = model("mace4_finite_model.txt")
      assert %Interpretation{kind: :finite, dialect: :standard} = model
      assert model.domains == %{"$i" => ["d0", "d1"]}
      assert model.constants == %{"a" => "d0", "b" => "d1"}
      assert model.functions == %{{"f", 1} => %{["d0"] => "d1", ["d1"] => "d0"}}

      assert model.predicates == %{
               {"p", 1} => %{["d0"] => true, ["d1"] => false},
               {"q", 2} => %{
                 ["d0", "d0"] => false,
                 ["d0", "d1"] => true,
                 ["d1", "d0"] => true,
                 ["d1", "d1"] => false
               }
             }
    end

    test "VampireFmb: the Vampire-FMo reply" do
      model = model("vampire_sat_finite_model.txt")
      assert %Interpretation{kind: :finite, dialect: :vampire_fmb} = model
      assert model.domains == %{"$i" => ["fmb_$i_1", "fmb_$i_2"]}
      assert model.constants == %{"a" => "fmb_$i_1", "b" => "fmb_$i_2"}

      assert model.functions[{"f", 1}] == %{
               ["fmb_$i_1"] => "fmb_$i_2",
               ["fmb_$i_2"] => "fmb_$i_1"
             }

      assert map_size(model.predicates[{"q", 2}]) == 4
    end

    test "FiRoles: the Paradox 4.0 reply, its compact rows written out" do
      model = model("paradox_finite_model.txt")
      assert %Interpretation{kind: :finite, dialect: :fi_roles} = model
      assert model.domains == %{"$i" => ["1", "2"]}
      assert model.functions == %{{"f", 1} => %{["1"] => "2", ["2"] => "2"}}

      assert model.predicates[{"q", 2}] ==
               %{["1", "1"] => true, ["1", "2"] => true, ["2", "1"] => true, ["2", "2"] => true}
    end

    test "a Saturation is a Herbrand model: E 3.5.1" do
      model = model("e_sat_saturation.txt")
      assert %Interpretation{kind: :herbrand, formulae: %Tptp.File{statements: [_ | _]}} = model
      assert model.functions == %{} and model.predicates == %{}
      assert IO.iodata_to_binary(Interpretation.to_tptp(model)) == model.formulae.source
    end

    test "interpretation-herbrand statements are a Herbrand model too" do
      {:ok, file, []} = Tptp.from_string("fof(h, interpretation-herbrand, p(a)).")
      assert {:ok, %Interpretation{kind: :herbrand}} = Interpretation.from_file(file)
    end

    test "worlds and typed domains are :partial" do
      {:ok, file, _} =
        Tptp.from_string(
          ~s|fof(w, interpretation-worlds, $true).\nfof(d, interpretation-domains, $distinct("w0")).|
        )

      assert {:ok, %Interpretation{kind: :partial}} = Interpretation.from_file(file)
    end

    test "a file no reader claims" do
      {:ok, file, []} = Tptp.from_string("fof(a, axiom, p).")
      assert Interpretation.from_file(file) == {:error, {:invalid_interpretation, :unrecognised}}
    end

    test "cvc5's SMT-LIB model is not TPTP" do
      [_, _, _, _, {id, text}] =
        SystemOnTptp.Reply.sections(File.read!("test/fixtures/sotp_raw_models.txt"))

      assert id == "cvc5-SAT---1.3.4"
      {:ok, result} = SystemOnTptp.read_section(id, text)
      assert {:error, {:invalid_interpretation, [_ | _]}} = Result.interpretation(result)
    end
  end

  describe "to_tptp/1" do
    test "round trip: Standard reads back equal tables for the three fixtures" do
      for name <- ~w(mace4_finite_model.txt vampire_sat_finite_model.txt paradox_finite_model.txt) do
        model = model(name)
        printed = model |> Interpretation.to_tptp() |> IO.iodata_to_binary()
        {:ok, file, []} = Tptp.from_string(printed)
        assert Standard.claims?(file)
        assert {:ok, read} = Interpretation.from_file(file)
        assert read.dialect == :standard
        assert tables(read) == tables(model), name
      end
    end

    test "elements that are not distinct objects are quoted" do
      printed =
        "vampire_sat_finite_model.txt"
        |> model()
        |> Interpretation.to_tptp()
        |> IO.iodata_to_binary()

      assert printed =~ ~s|X = "fmb_$i_1"|
      assert printed =~ ~s|a = "fmb_$i_1"|
    end

    test "a typed model prints as declared tff and reads back, :partial" do
      model = %Interpretation{
        kind: :partial,
        dialect: :vampire_fmb,
        source: "",
        domains: %{"point" => ["fmb_point_1", "fmb_point_2"], "$i" => ["fmb_$i_1"]},
        constants: %{"c" => "fmb_$i_1"},
        functions: %{
          {"f", 2} => %{
            ["fmb_point_1", "fmb_$i_1"] => "fmb_point_2",
            ["fmb_point_2", "fmb_$i_1"] => "fmb_point_2"
          }
        },
        predicates: %{{"p", 1} => %{["fmb_point_1"] => true, ["fmb_point_2"] => false}}
      }

      printed = model |> Interpretation.to_tptp() |> IO.iodata_to_binary()

      assert printed =~ "tff(type_point, type, point: $tType)."
      assert printed =~ "tff(declare_f, type, f: (point * $i) > point)."
      assert printed =~ "tff(declare_p, type, p: point > $o)."
      assert printed =~ "$distinct(fmb_point_1, fmb_point_2)"
      refute printed =~ ~s|"fmb_point_1"|

      {:ok, file, []} = Tptp.from_string(printed)
      assert {:ok, read} = Interpretation.from_file(file)
      assert read.kind == :partial
      assert read.domains == model.domains
      assert tables(read) == tables(model)
    end

    test "an interpretation is an AtpClient.Input" do
      model = model("mace4_finite_model.txt")
      assert AtpClient.Input.to_iodata(model) == Interpretation.to_tptp(model)
    end
  end

  describe "Nitpick" do
    defp payload(name),
      do: name |> then(&File.read!(Path.join("test/fixtures", &1))) |> Jason.decode!()

    test "the captured counterexample" do
      message =
        "isabelle_nitpick_payload.json"
        |> payload()
        |> AtpClient.Isabelle.Verdict.texts()
        |> Nitpick.message()

      assert {:ok, model, []} = Nitpick.read(message)
      assert %Interpretation{kind: :partial, dialect: :nitpick, source: ^message} = model

      assert model.domains == %{
               "'a" => ["a1", "a2", "a3", "a4"],
               "'b" => ["b1", "b2", "b3", "b4"]
             }

      assert model.constants == %{"x" => "a4", "y" => "a4"}
      assert model.predicates[{"A", 1}] == %{["b1"] => true, ["b3"] => true}
      assert model.defaults[{"A", 1}] == false

      assert model.predicates[{"P", 1}] == %{
               ["a1"] => false,
               ["a2"] => true,
               ["a3"] => true,
               ["a4"] => true
             }

      assert model.functions[{"f", 1}] == %{
               ["a1"] => "a2",
               ["a2"] => "a2",
               ["a3"] => "a4",
               ["a4"] => "a2"
             }

      assert model.defaults[{"f", 1}] == "_"
    end

    test "a Skolem constant, and a function left undefined" do
      message =
        "isabelle_nitpick_skolem_payload.json"
        |> payload()
        |> AtpClient.Isabelle.Verdict.texts()
        |> Nitpick.message()

      assert {:ok, model, []} = Nitpick.read(message)
      assert model.constants == %{"x" => "a1"}
      assert model.predicates == %{{"P", 1} => %{["a1"] => false}}
      assert model.functions == %{}
    end

    test "curried functions and Unicode symbols" do
      message = """
      Nitpick found a model for card 'a = 2:
        Constant:
          g = (λx. _)(a₁ := (λx. _)(a₁ := True, a₂ := False), a₂ := (λx. _)(a₁ := False, a₂ := True))
      """

      assert {:ok, model, []} = Nitpick.read(message)

      assert model.predicates[{"g", 2}] == %{
               ["a1", "a1"] => true,
               ["a1", "a2"] => false,
               ["a2", "a1"] => false,
               ["a2", "a2"] => true
             }
    end

    test "Result.interpretation/1 dispatches on Isabelle evidence" do
      message = "Nitpick found a counterexample:\n  Free variable:\n    x = True"

      result = %Result{
        status: :counter_satisfiable,
        evidence: {:backend, AtpClient.Isabelle},
        output: message,
        backend: AtpClient.Isabelle,
        details: %{nitpick: message}
      }

      assert {:ok, %Interpretation{predicates: %{{"x", 0} => %{[] => true}}}, []} =
               Result.interpretation(result)

      assert Result.interpretation(%{result | details: %{}}) == :none
    end
  end
end
