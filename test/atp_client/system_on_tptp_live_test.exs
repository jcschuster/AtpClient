defmodule AtpClient.SystemOnTptpLiveTest do
  use ExUnit.Case, async: false

  # Live tests against tptp.org's public SystemOnTPTPFormReply endpoint.
  # Excluded by default (see `test/test_helper.exs`); run with:
  #
  #     mix test --include sotptp_live
  #
  # These pin the wire contract for the per-system flag overrides
  # (`:command`, `:format`, `:transform`) added alongside the NimbleOptions
  # validation work. The behaviour recorded here was measured directly
  # against tptp.org on 2026-07-20; if tptp.org's semantics change, this
  # is where you'll find out.

  @moduletag :sotptp_live

  # The `E` prover has been on SotP for years and its identifier is stable
  # across releases (up to the version suffix). We pin a specific version
  # to keep the test deterministic — bump when tptp.org rolls a new one.
  @system "E---3.5.1"

  # Trivial FOF problem that E can discharge in tens of milliseconds.
  # Kept as a module attribute so the tests are cheap and don't strain
  # the shared endpoint.
  @socrates """
  fof(human_mortal, axiom, ! [X] : (human(X) => mortal(X))).
  fof(socrates_human, axiom, human(socrates)).
  fof(socrates_mortal, conjecture, mortal(socrates)).
  """

  describe "baseline" do
    test "query_system/3 with no overrides discharges the conjecture" do
      assert {:ok, :theorem} =
               AtpClient.SystemOnTptp.query_system(@socrates, @system, time_limit_sec: 10)
    end
  end

  describe ":format override" do
    test "an unknown format module makes SotP return a Formatter error" do
      # Confirmed by a hand-crafted curl during design: SotP replies with
      # an `ERROR: Formatter did not create ...` body when the value is
      # not a known format module. That surfaces to us as an
      # unrecognised-output failure rather than a classified SZS status.
      {:ok, raw} =
        AtpClient.SystemOnTptp.query_system(
          @socrates,
          @system,
          time_limit_sec: 5,
          format: "tptp:definitely_not_a_real_format_module",
          raw: true
        )

      assert raw =~ "Formatter did not create"
    end

    test "the default format module `tptp:raw` still discharges the conjecture" do
      # Pinning the null case: passing the *default* value explicitly must
      # behave identically to passing nothing.
      assert {:ok, :theorem} =
               AtpClient.SystemOnTptp.query_system(@socrates, @system,
                 time_limit_sec: 10,
                 format: "tptp:raw"
               )
    end
  end

  describe ":transform override" do
    test "an unknown transform module makes SotP return a Formatter error" do
      # Bogus transforms cascade into the same "Formatter did not create"
      # error path — see the design-time probe.
      {:ok, raw} =
        AtpClient.SystemOnTptp.query_system(
          @socrates,
          @system,
          time_limit_sec: 5,
          transform: "definitely_not_a_real_transform",
          raw: true
        )

      assert raw =~ "Formatter did not create"
    end
  end

  describe ":command override" do
    test "tptp.org silently ignores :command and runs the default wrapper" do
      # Design-time probe: passing an obviously bogus command line — a path
      # that cannot exist — still yields a Theorem. This test locks in
      # that observed behaviour so a future change on the SotP side (e.g.
      # a deployment that starts honouring `Command___`) surfaces here as
      # a red test rather than silently altering results.
      assert {:ok, :theorem} =
               AtpClient.SystemOnTptp.query_system(@socrates, @system,
                 time_limit_sec: 10,
                 command: "/nonexistent/binary %s %d"
               )
    end
  end
end
