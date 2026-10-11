defmodule AtpClient.Analyzer.Tptp4xTest do
  use ExUnit.Case, async: true

  alias AtpClient.Analyzer.Tptp4x
  alias Tptp.Diagnostic
  alias Tptp.Span

  # TPTP4X positions are one-based line and character; the analyzer turns
  # them into byte offsets on this source.
  @source "fof(a, axiom, p)).\nfof(b, axiom, f(X: $i)).\n"
  @index Span.line_index(@source)

  describe "parse/3" do
    test "an ERROR with a Token preamble becomes an error at that offset" do
      body = """
      % START OF SYSTEM OUTPUT
      ERROR: Line 1 Char 17 Token ")" continuing with "." : Illegal punctuation here
      % END OF SYSTEM OUTPUT
      % RESULT: SOT__Ed3Zp - TPTP4X---0.0 says Unknown - CPU = 0.00 WC = 0.01
      """

      assert [
               %Diagnostic{
                 code: "TPTP4X",
                 severity: :error,
                 message: "Illegal punctuation here",
                 span: %Span{file: 0, offset: 16, length: 0}
               }
             ] = Tptp4x.parse(body, @index)
    end

    test "a position on a later line resolves through the line index" do
      body = """
      ERROR: Line 2 Char 18 Token "$i" continuing with ")." : Wrong token type or value, expected punctuation with value ")"
      """

      assert [%Diagnostic{severity: :error, span: %Span{offset: offset}}] =
               Tptp4x.parse(body, @index)

      assert binary_part(@source, offset, 2) == ": "
    end

    test "a WARNING is a warning, and the file id is the one given" do
      body = "WARNING: Line 1 Char 1 Something to look at\n"

      assert [%Diagnostic{severity: :warning, span: %Span{file: 3, offset: 0}}] =
               Tptp4x.parse(body, @index, 3)
    end

    test "a position outside the source is reported at offset 0" do
      body = "ERROR: Line 40 Char 2 Beyond the end\n"

      assert [%Diagnostic{span: %Span{offset: 0}, message: "Beyond the end"}] =
               Tptp4x.parse(body, @index)
    end

    test "a clean echo produces no diagnostics" do
      body = """
      % START OF SYSTEM OUTPUT
      fof(a, axiom, p).
      % END OF SYSTEM OUTPUT
      % RESULT: SOT_xxx - TPTP4X---0.0 says Unknown - CPU = 0.00 WC = 0.01
      """

      assert Tptp4x.parse(body, @index) == []
    end

    test "diagnostics come back in source order" do
      body = """
      ERROR: Line 2 Char 1 second
      ERROR: Line 1 Char 1 first
      """

      assert ["first", "second"] = body |> Tptp4x.parse(@index) |> Enum.map(& &1.message)
    end
  end

  describe "as a Tptp.Analyzer" do
    test "declares itself" do
      assert Tptp4x.id() == :tptp4x
      assert Tptp4x.label() == "TPTP4X"
      assert Tptp4x.dialects() == :any
    end

    test "an unreachable deployment is no finding" do
      analysis = Tptp.analyze(@source)

      assert Tptp.Analyzer.run_all(analysis, [Tptp4x],
               tptp4x: [url: "http://127.0.0.1:1/nowhere", request_timeout_ms: 200]
             ) == [{:tptp4x, []}]
    end

    test "check/2 reports the failure instead" do
      analysis = Tptp.analyze(@source)

      assert {:error, _reason} =
               Tptp4x.check(analysis, url: "http://127.0.0.1:1/nowhere", request_timeout_ms: 200)
    end
  end
end
