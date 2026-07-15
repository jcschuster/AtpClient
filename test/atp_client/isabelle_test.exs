defmodule AtpClient.IsabelleTest do
  use ExUnit.Case, async: false

  alias AtpClient.Isabelle
  alias AtpClient.Isabelle.Session

  describe "open_session/1 safety" do
    test "returns {:error, _} against an unreachable host without killing a non-trapping caller" do
      # Sanity: this test process must NOT be trapping exits — the SessionOwner
      # indirection exists precisely so non-trapping callers survive a failed
      # Shared.start_link.
      refute Process.flag(:trap_exit, false)

      assert {:error, _reason} =
               Isabelle.open_session(
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
  # `AtpClient.Isabelle.SessionOwner`. The `SessionOwner` GenServer monitors
  # the caller of `open_session/1`; on caller :DOWN it stops
  # `IsabelleClient.Shared`, whose `terminate/2` closes the TCP socket to
  # the Isabelle server. Closing the socket aborts any in-flight
  # `use_theories` task on the server.
  #
  # These tests require a running Isabelle server. They are excluded by
  # default (see test_helper.exs). Run with:
  #
  #     ISABELLE_PORT=... ISABELLE_PASSWORD=... \
  #       mix test --include isabelle_server test/atp_client/isabelle_test.exs
  describe "cancellation contract (requires live server)" do
    @describetag :isabelle_server

    setup do
      port = System.get_env("ISABELLE_PORT") |> require_env("ISABELLE_PORT") |> String.to_integer()
      password = System.get_env("ISABELLE_PASSWORD") |> require_env("ISABELLE_PASSWORD")
      host = System.get_env("ISABELLE_HOST", "127.0.0.1")

      local_dir =
        Path.join(System.tmp_dir!(), "atp_client_isabelle_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(local_dir)
      on_exit(fn -> File.rm_rf!(local_dir) end)

      opts = [
        host: host,
        port: port,
        password: password,
        local_dir: local_dir,
        session: System.get_env("ISABELLE_SESSION", "HOL"),
        session_start_timeout_ms: 240_000,
        use_theories_timeout_ms: 60_000
      ]

      # HOL session boot is multi-second; pre-warm so the test process can
      # measure cancellation latency, not session-build latency.
      {:ok, warm} = Isabelle.open_session(opts)
      :ok = Isabelle.close_session(warm)

      {:ok, opts: opts}
    end

    test "caller death tears down SessionOwner and IsabelleClient.Shared", %{opts: opts} do
      parent = self()

      victim =
        spawn(fn ->
          case Isabelle.open_session(opts) do
            {:ok, vs} ->
              send(parent, {:session, Session.owner(vs), Session.client(vs)})
              Process.sleep(:infinity)

            err ->
              send(parent, {:fail, err})
          end
        end)

      {owner, client} =
        receive do
          {:session, o, c} -> {o, c}
          {:fail, err} -> flunk("victim could not open session: #{inspect(err)}")
        after
          60_000 -> flunk("victim never reported its session")
        end

      assert Process.alive?(owner)
      assert Process.alive?(client)

      owner_ref = Process.monitor(owner)
      client_ref = Process.monitor(client)

      Process.exit(victim, :kill)

      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _}, 10_000
      assert_receive {:DOWN, ^client_ref, :process, ^client, _}, 10_000
    end

    test "caller death mid-`use_theories` aborts the task and leaves the server healthy",
         %{opts: opts} do
      # A non-trivial theory: a `sledgehammer` over several ATPs that should
      # take a few seconds, long enough for us to kill the caller while the
      # task is in flight on the server.
      slow_body = ~S"""
      lemma slow: "(x::nat) \<le> x + 1" sledgehammer (cvc4 e spass vampire)
      oops
      """

      parent = self()

      victim =
        spawn(fn ->
          case Isabelle.open_session(opts) do
            {:ok, vs} ->
              send(parent, {:session, Session.owner(vs), Session.client(vs)})
              res = Isabelle.prove_theory(vs, slow_body, "SlowProbe", opts)
              send(parent, {:result, res})

            err ->
              send(parent, {:fail, err})
          end
        end)

      {owner, client} =
        receive do
          {:session, o, c} -> {o, c}
          {:fail, err} -> flunk("victim could not open session: #{inspect(err)}")
        after
          60_000 -> flunk("victim never reported its session")
        end

      # Wait for use_theories to actually be in flight on the server.
      Process.sleep(500)

      owner_ref = Process.monitor(owner)
      client_ref = Process.monitor(client)
      Process.exit(victim, :kill)

      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _}, 10_000
      assert_receive {:DOWN, ^client_ref, :process, ^client, _}, 10_000

      # Server should still be reachable after the abort.
      {:ok, fresh} = Isabelle.open_session(opts)

      try do
        result = Isabelle.prove_theory(fresh, "lemma ok: \"True\" by simp\n", "Sanity", opts)
        # prove_theory returns the single-wrapped atp_result() since 0.6.0.
        assert {:ok, :theorem} = result
      after
        Isabelle.close_session(fresh)
      end
    end
  end

  defp require_env(nil, var), do: flunk("set #{var} to run this test")
  defp require_env(value, _var), do: value
end
