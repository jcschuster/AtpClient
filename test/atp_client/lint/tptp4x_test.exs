defmodule AtpClient.Lint.Tptp4xTest do
  use ExUnit.Case, async: true
  alias AtpClient.Lint.Tptp4x
  alias AtpClient.Lint.Diagnostic

  test "parses an ERROR with Token preamble" do
    body = """
    % START OF SYSTEM OUTPUT
    ERROR: Line 1 Char 19 Token ")" continuing with "." : Illegal punctuation here
    % END OF SYSTEM OUTPUT
    % RESULT: SOT__Ed3Zp - TPTP4X---0.0 says Unknown - CPU = 0.00 WC = 0.01
    """

    assert [
             %Diagnostic{
               line: 1,
               column: 19,
               severity: :error,
               message: "Illegal punctuation here",
               source: "tptp4x"
             }
           ] = Tptp4x.parse_output(body)
  end

  test "parses an ERROR pointing past the offending token" do
    body = """
    % START OF SYSTEM OUTPUT
    ERROR: Line 1 Char 21 Token "$i" continuing with ")." : Wrong token type or value, expected punctuation with value ")"
    % END OF SYSTEM OUTPUT
    """

    assert [%Diagnostic{line: 1, column: 21, severity: :error}] =
             Tptp4x.parse_output(body)
  end

  test "well-formed input produces no diagnostics" do
    body = """
    % START OF SYSTEM OUTPUT
    fof(a, axiom, p).
    % END OF SYSTEM OUTPUT
    % RESULT: SOT_xxx - TPTP4X---0.0 says Unknown - CPU = 0.00 WC = 0.01
    """

    assert Tptp4x.parse_output(body) == []
  end
end
