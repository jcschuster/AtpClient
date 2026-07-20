defmodule AtpClient.OptsValidationTest do
  use ExUnit.Case, async: true

  # NimbleOptions is wired into every public entry point across the four
  # backends and the lint pipeline. These tests are the guardrail: they
  # confirm that unknown option keys and obviously-wrong value types raise
  # `NimbleOptions.ValidationError` (a subclass of ArgumentError) at the
  # entry point, before the function does any real work.
  #
  # `assert_raise NimbleOptions.ValidationError` pins the mechanism, not
  # just the exception hierarchy — a callsite that later switches to a
  # hand-rolled validator would fail this test.

  describe "AtpClient.SystemOnTptp" do
    test "query/2 rejects an unknown key" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown option/, fn ->
        AtpClient.SystemOnTptp.query("fof(g,conjecture,$true).", time_limit: 5)
      end
    end

    test "query_system/3 accepts the documented per-system override keys" do
      # An unroutable URL kicks the call out at the transport layer, which
      # is fine — the point is that NimbleOptions did not raise on the
      # keys themselves.
      assert {:error, _} =
               AtpClient.SystemOnTptp.query_system(
                 "fof(g,conjecture,$true).",
                 "E---3.5.1",
                 url: "http://127.0.0.1:1/nowhere",
                 time_limit_sec: 1,
                 command: "run_E %s %d THM",
                 format: "tptp:raw",
                 transform: "none"
               )
    end

    test "query_system/3 rejects a non-boolean :raw" do
      assert_raise NimbleOptions.ValidationError, ~r/expected boolean/, fn ->
        AtpClient.SystemOnTptp.query_system(
          "fof(g,conjecture,$true).",
          "E---3.5.1",
          raw: "yes"
        )
      end
    end
  end

  describe "AtpClient.StarExec" do
    test "verify/1 rejects an unknown key" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown option/, fn ->
        # Typo: `:user` instead of `:username`.
        AtpClient.StarExec.verify(base_url: "http://x", user: "u", password: "p")
      end
    end

    test "query/2 accepts a Req pass-through option (`:receive_timeout`)" do
      # `:receive_timeout` isn't a StarExec-specific option — it's a Req
      # option that flows through `request/4`. The schema folds in the
      # documented Req pass-through allowlist as `type: :any`, so it must
      # not be rejected here. Value shape only; the unreachable base_url
      # will fail the transport, not the validator.
      assert {:error, _} =
               AtpClient.StarExec.query("fof(c,conjecture,$true).",
                 base_url: "http://127.0.0.1:1",
                 username: "u",
                 password: "p",
                 receive_timeout: 100
               )
    end
  end

  describe "AtpClient.Isabelle" do
    test "verify/1 rejects an unknown key" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown option/, fn ->
        AtpClient.Isabelle.verify(hostt: "127.0.0.1", port: 9999, password: "x")
      end
    end

    test "query/2 rejects a non-integer :port" do
      assert_raise NimbleOptions.ValidationError, ~r/expected positive integer/, fn ->
        AtpClient.Isabelle.query("thf(g,conjecture,$true).", port: "nine")
      end
    end
  end

  describe "AtpClient.LocalExec" do
    test "query/2 rejects an unknown key" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown option/, fn ->
        # Typo: `:cpu_timeout` instead of `:cpu_timeout_s`.
        AtpClient.LocalExec.query("fof(c,conjecture,$true).",
          binary: "sh",
          cpu_timeout: 1
        )
      end
    end

    test "query/2 validates :args shape but not its contents" do
      # `:args` must be a list — NimbleOptions rejects a bare string.
      # The *contents* of the list are prover-specific flags and are
      # deliberately opaque; the schema does not inspect them.
      assert_raise NimbleOptions.ValidationError, ~r/expected list/, fn ->
        AtpClient.LocalExec.query("fof(c,conjecture,$true).",
          binary: "sh",
          args: "--auto --cpu-limit=5"
        )
      end
    end
  end

  describe "AtpClient.Lint" do
    test "analyze/2 rejects an unknown key" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown option/, fn ->
        AtpClient.Lint.analyze("fof(a,axiom,p).", backend: [:local])
      end
    end

    test "analyze/2 restricts :backends to the two documented atoms" do
      assert_raise NimbleOptions.ValidationError, ~r/(invalid list element|expected one of)/, fn ->
        AtpClient.Lint.analyze("fof(a,axiom,p).", backends: [:local, :nonsense])
      end
    end
  end
end
