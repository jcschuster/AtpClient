defmodule AtpClient.IsabelleTest do
  use ExUnit.Case, async: true

  describe "open_session/1 safety" do
    test "returns {:error, _} against an unreachable host without killing a non-trapping caller" do
      # Sanity: this test process must NOT be trapping exits — the SessionOwner
      # indirection exists precisely so non-trapping callers survive a failed
      # Shared.start_link.
      refute Process.flag(:trap_exit, false)

      assert {:error, _reason} =
               AtpClient.Isabelle.open_session(
                 host: "127.0.0.1",
                 port: 1,
                 password: "x",
                 local_dir: "/tmp",
                 session_start_timeout_ms: 1_000
               )

      # If the safety guarantee held, we are still alive to make this assertion.
      assert Process.alive?(self())
    end
  end

  # Cancellation contract — see `AtpClient.Isabelle` moduledoc and
  # `AtpClient.Isabelle.SessionOwner`. The `SessionOwner` GenServer
  # monitors the caller of `open_session/1`; on caller :DOWN it stops
  # `IsabelleClient.Shared`, whose `terminate/2` closes the TCP socket to
  # the Isabelle server. Closing the socket aborts any in-flight
  # `use_theories` task. A real Isabelle server is not available in this
  # test environment, so the end-to-end cancellation path is exercised by
  # the `isabelle_test.exs` / `isabelle_theory_test.exs` integration
  # suites against a running server.
end
