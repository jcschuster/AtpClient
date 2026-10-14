defmodule AtpClient.SystemOnTptp.SystemsTest do
  use ExUnit.Case, async: true

  alias AtpClient.SystemOnTptp.Systems

  doctest Systems

  @systems [
    "E---3.5.1",
    "Vampire---5.0.1",
    "Vampire---4.8",
    "Vampire-FMo---5.0.1",
    "TPTP4X---0.0"
  ]

  describe "resolve/2" do
    test "an identifier must be advertised as written" do
      assert Systems.resolve("E---3.5.1", @systems) == {:ok, "E---3.5.1"}
      assert Systems.resolve("E---3.5.0", @systems) == {:error, {:unknown_system, "E---3.5.0"}}
    end

    test "a name resolves to its latest advertised version" do
      assert Systems.resolve("Vampire", @systems) == {:ok, "Vampire---5.0.1"}
      assert Systems.resolve("E", @systems) == {:ok, "E---3.5.1"}
    end

    test "a name matches whole, not as a prefix" do
      assert Systems.resolve("Vampire-FMo", @systems) == {:ok, "Vampire-FMo---5.0.1"}
      assert Systems.resolve("Vamp", @systems) == {:error, {:unknown_system, "Vamp"}}
    end

    test "versions compare component-wise as numbers" do
      systems = ["X---2.1.9999", "X---2.1.10", "X---2.10", "X---2.1"]
      assert Systems.resolve("X", systems) == {:ok, "X---2.10"}

      systems = ["Y---2023.07.24", "Y---2024.01.09", "Y---1.9"]
      assert Systems.resolve("Y", systems) == {:ok, "Y---2024.01.09"}

      systems = ["Z---1.2", "Z---1.2.3", "Z---1.2a"]
      assert Systems.resolve("Z", systems) == {:ok, "Z---1.2a"}
    end

    test "tools are resolvable, since the deployment advertises them" do
      assert Systems.resolve("TPTP4X", @systems) == {:ok, "TPTP4X---0.0"}
    end

    test "without a list, an identifier passes through and a name cannot be resolved" do
      assert Systems.resolve("Nope---1", []) == {:ok, "Nope---1"}
      assert Systems.resolve("Nope", []) == {:error, {:unknown_system, "Nope"}}
    end
  end
end
