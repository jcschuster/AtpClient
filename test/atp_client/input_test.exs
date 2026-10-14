defmodule AtpClient.InputTest do
  use ExUnit.Case, async: true

  alias AtpClient.Input
  alias Tptp.Printer.Canonical

  @source "fof(a, axiom, p).\n% a comment\nfof(b, conjecture, p).\n"

  describe "a binary" do
    test "is its own bytes" do
      assert Input.to_iodata(@source) == @source
      assert Input.name(@source) == nil
    end
  end

  describe "iodata" do
    test "is passed as given" do
      iodata = ["fof(a, axiom, ", "p).\n"]
      assert Input.to_iodata(iodata) == iodata
      assert Input.name(iodata) == nil
    end

    test "a printed tree is iodata" do
      {:ok, file, []} = Tptp.from_string(@source)
      iodata = Canonical.to_iodata(file)
      assert IO.iodata_to_binary(Input.to_iodata(iodata)) == IO.iodata_to_binary(iodata)
    end
  end

  describe "a Tptp.File" do
    test "is the source it was read from, comments included" do
      {:ok, file, []} = Tptp.from_string(@source)
      assert Input.to_iodata(file) == @source
    end

    test "is the very same binary, not a copy" do
      {:ok, file, []} = Tptp.from_string(@source)
      assert :erts_debug.same(Input.to_iodata(file), file.source)
    end

    test "is named after its path" do
      {:ok, file, []} = Tptp.from_string(@source)
      assert Input.name(file) == nil
      assert Input.name(%{file | path: "Problems/PUZ/PUZ001+1.p"}) == "PUZ001+1.p"
    end
  end

  describe "a Tptp.Unit" do
    @axioms "fof(ax1, axiom, p).\nfof(ax2, axiom, q).\n"
    @root "include('a.ax').\nfof(c, conjecture, p & q).\n"

    test "is its statements with includes expanded in place" do
      resolver = {Tptp.Resolver.Map, files: %{"a.ax" => @axioms}}
      {:ok, unit, []} = Tptp.Unit.from_string(@root, resolver: resolver)

      assert IO.iodata_to_binary(Input.to_iodata(unit)) ==
               "fof(ax1, axiom, p).\nfof(ax2, axiom, q).\nfof(c, conjecture, p & q).\n"
    end

    test "applies a selection" do
      resolver = {Tptp.Resolver.Map, files: %{"a.ax" => @axioms}}

      {:ok, unit, []} =
        Tptp.Unit.from_string("include('a.ax', [ax2]).\nfof(c, conjecture, q).\n",
          resolver: resolver
        )

      assert IO.iodata_to_binary(Input.to_iodata(unit)) ==
               "fof(ax2, axiom, q).\nfof(c, conjecture, q).\n"
    end

    test "slices statements from their files rather than copying them" do
      # A sub-binary references its whole parent, a copy only its own bytes.
      # The runtime materialises slices of up to 64 bytes as heap binaries
      # of their own, so the statement has to be longer than that for the
      # distinction to be observable.
      long = "fof(ax1, axiom, " <> String.duplicate("p & ", 30) <> "p).\n"
      axioms = long <> "fof(ax2, axiom, q).\n"
      resolver = {Tptp.Resolver.Map, files: %{"a.ax" => axioms}}
      {:ok, unit, []} = Tptp.Unit.from_string(@root, resolver: resolver)

      [[first, ?\n] | _] = Input.to_iodata(unit)
      assert first <> "\n" == long
      assert :binary.referenced_byte_size(first) == byte_size(axioms)
    end

    test "an include the unit did not resolve contributes nothing" do
      {:ok, unit, _diagnostics} = Tptp.Unit.from_string(@root)
      assert IO.iodata_to_binary(Input.to_iodata(unit)) == "fof(c, conjecture, p & q).\n"
    end

    test "is named after its root" do
      resolver = {Tptp.Resolver.Map, files: %{"a.ax" => @axioms}}
      {:ok, unit, []} = Tptp.Unit.from_string(@root, resolver: resolver, path: "x/root.p")
      assert Input.name(unit) == "root.p"
    end
  end

  describe "AtpClient.preflight/1" do
    test "a well-formed problem passes" do
      assert AtpClient.preflight(@source) == :ok
    end

    test "an analysed file is not parsed again" do
      {:ok, file, []} = Tptp.from_string(@source)
      assert AtpClient.preflight(file) == :ok
    end

    test "a problem that does not parse is rejected with its diagnostics" do
      assert {:error, {:invalid_problem, diagnostics}} = AtpClient.preflight("fof(a, axiom, p")
      assert Tptp.Diagnostic.any_errors?(diagnostics)
    end

    test "a warning does not reject" do
      # Two conjectures is a lint warning, not an error.
      assert :ok = AtpClient.preflight("fof(a, conjecture, p).\nfof(b, conjecture, q).\n")
    end
  end

  describe "AtpClient.query/3" do
    @describetag :posix_shell

    test "runs the preflight before the backend when asked" do
      assert {:error, {:invalid_problem, _}} =
               AtpClient.query(AtpClient.LocalExec, "fof(a, axiom, p",
                 binary: "sh",
                 preflight: true
               )
    end

    test "sends the problem straight to the backend otherwise" do
      # No binary named `atp_client_no_such_prover` exists, so the backend is
      # reached and reports that, which is the proof the preflight was skipped.
      assert {:error, {:prover_not_found, _}} =
               AtpClient.query(AtpClient.LocalExec, "fof(a, axiom, p",
                 binary: "atp_client_no_such_prover"
               )
    end
  end

  describe "Tptp.Derivation" do
    test "is the source of its file, named after it" do
      {:ok, file, []} = Tptp.from_string(@source, path: "Problems/X.p")
      {:ok, derivation, _} = Tptp.Derivation.from_file(file)
      assert Input.to_iodata(derivation) == @source
      assert Input.name(derivation) == "X.p"
    end
  end

  describe "the deprecated AtpClient.Problem" do
    @tag :capture_log
    test "delegates to AtpClient.Input" do
      {:ok, file, []} = Tptp.from_string(@source)
      # credo:disable-for-next-line
      assert apply(AtpClient.Problem, :to_iodata, [file]) == @source
      assert apply(AtpClient.Problem, :name, ["x"]) == nil
    end
  end
end
