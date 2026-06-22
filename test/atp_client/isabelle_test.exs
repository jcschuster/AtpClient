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
end
