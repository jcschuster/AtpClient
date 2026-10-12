defmodule AtpClient.SystemOnTptpTest do
  use ExUnit.Case, async: false

  alias AtpClient.Result
  alias AtpClient.SystemOnTptp
  alias AtpClient.SystemOnTptp.Provers

  # The Application's TptpFinch pool is `protocols: [:http1]` with TLS verify
  # configured. For these tests we point at a local TCP listener that accepts
  # connections but never writes back, so the HTTP transaction stalls and we
  # can assert what happens when the caller is killed mid-flight.
  defp start_slow_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: 0, active: false, reuseaddr: true])
    {:ok, port_no} = :inet.port(listen)
    parent = self()

    acceptor =
      spawn(fn -> accept_loop(listen, parent) end)

    {port_no, acceptor, listen}
  end

  defp accept_loop(listen, parent) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, sock} ->
        send(parent, {:accepted, sock})
        accept_loop(listen, parent)

      {:error, _} ->
        :ok
    end
  end

  describe "cancellation" do
    test "killing the calling Task does not leave the Finch pool wedged" do
      {port_no, _acceptor, listen} = start_slow_server()
      url = "http://127.0.0.1:#{port_no}/SystemOnTPTPFormReply"

      task =
        Task.async(fn ->
          SystemOnTptp.query_system(
            "fof(a, conjecture, p).",
            "Vampire-FMo---5.0.1",
            url: url,
            time_limit_sec: 60
          )
        end)

      assert_receive {:accepted, _sock}, 5_000

      # Mid-flight kill. Task.shutdown(:brutal_kill) maps to Process.exit/2
      # with :kill on the Task pid — the same path MCP cancellation uses.
      Task.shutdown(task, :brutal_kill)

      # The pool must still be usable for a fresh request. The fake server
      # never replies, so we expect an error from receive_timeout — not a
      # hang and not a Finch pool checkout timeout.
      #
      # `network_overhead_ms: 100` shrinks each attempt's receive_timeout
      # from the 30 s production default to 100 ms so the Req retry loop
      # bails out well inside ExUnit's 60 s test timeout: the pool
      # assertion below is what matters, not how long the retries take.
      result =
        SystemOnTptp.query_system(
          "fof(a, conjecture, p).",
          "Vampire-FMo---5.0.1",
          url: url,
          time_limit_sec: 0,
          network_overhead_ms: 100
        )

      assert match?({:error, _}, result),
             "expected {:error, _} from the fake server but got #{inspect(result)}"

      :gen_tcp.close(listen)
    end
  end

  # A one-shot HTTP server: accepts one request, hands its body to the test,
  # and answers with `reply`.
  defp start_canned_server(reply) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port_no} = :inet.port(listen)
    parent = self()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      request = read_request(sock, "")
      send(parent, {:request, request})

      :gen_tcp.send(
        sock,
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{byte_size(reply)}\r\n" <>
          "Connection: close\r\n\r\n" <> reply
      )

      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
    end)

    "http://127.0.0.1:#{port_no}/SystemOnTPTPFormReply"
  end

  defp read_request(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        [_, length] = Regex.run(~r/content-length:\s*(\d+)/i, head)
        read_body(sock, body, String.to_integer(length))

      [_partial] ->
        {:ok, chunk} = :gen_tcp.recv(sock, 0, 5_000)
        read_request(sock, acc <> chunk)
    end
  end

  defp read_body(_sock, body, length) when byte_size(body) >= length, do: URI.decode_query(body)

  defp read_body(sock, body, length) do
    {:ok, chunk} = :gen_tcp.recv(sock, 0, 5_000)
    read_body(sock, body <> chunk, length)
  end

  # The agent holds whatever the last refresh produced — nothing, in a test
  # run with no route to tptp.org. These tests need a list to resolve
  # against, so they put one in and restore the previous state afterwards.
  defp with_advertised(systems, fun) do
    previous = Agent.get(Provers, & &1)
    Agent.update(Provers, fn _ -> %{systems: systems, provers: systems} end)

    try do
      fun.()
    after
      Agent.update(Provers, fn _ -> previous end)
    end
  end

  @rule "%" <> String.duplicate("-", 78) <> "\n"
  @separator @rule <> @rule

  defp section(id, status) do
    "% File     : #{id}\n% Problem  : SOT_x\n% SZS status #{status} for SOT_x\n"
  end

  describe "query_selected_systems/3" do
    test "resolves names, keeps unknown systems out of the request, and reports every system given" do
      reply =
        section("E---3.5.1", "Theorem") <> @separator <> section("Vampire---5.0.1", "Theorem")

      url = start_canned_server(reply)

      with_advertised(["E---3.5.1", "Vampire---5.0.1"], fn ->
        assert {:ok, outcomes} =
                 SystemOnTptp.query_selected_systems(
                   "fof(a, conjecture, p).",
                   ["E", "Nope---1", "Vampire---5.0.1"],
                   url: url,
                   time_limit_sec: 1
                 )

        assert [
                 {"E---3.5.1", {:ok, %Result{status: :theorem, system: "E---3.5.1"}}},
                 {"Nope---1", {:error, {:unknown_system, "Nope---1"}}},
                 {"Vampire---5.0.1", {:ok, %Result{status: :theorem}}}
               ] = outcomes
      end)

      assert_receive {:request, form}, 5_000
      refute Map.has_key?(form, "System___Nope---1")
      assert form["System___E---3.5.1"] == "E---3.5.1"
      assert form["System___Vampire---5.0.1"] == "Vampire---5.0.1"
    end

    test "the form lists the systems in the order given, not sorted by name" do
      reply =
        section("Vampire---5.0.1", "Theorem") <> @separator <> section("E---3.5.1", "Theorem")

      url = start_canned_server(reply)

      with_advertised(["E---3.5.1", "Vampire---5.0.1"], fn ->
        assert {:ok, [{"Vampire---5.0.1", _}, {"E---3.5.1", _}]} =
                 SystemOnTptp.query_selected_systems(
                   "fof(a, conjecture, p).",
                   ["Vampire", "E"],
                   url: url,
                   time_limit_sec: 1
                 )
      end)

      assert_receive {:request, _form}, 5_000
    end

    test "a system the deployment returned no section for is reported, not dropped" do
      url = start_canned_server(section("E---3.5.1", "Theorem"))

      with_advertised(["E---3.5.1", "Vampire---5.0.1"], fn ->
        assert {:ok,
                [
                  {"E---3.5.1", {:ok, %Result{status: :theorem}}},
                  {"Vampire---5.0.1", {:error, :no_output}}
                ]} =
                 SystemOnTptp.query_selected_systems(
                   "fof(a, conjecture, p).",
                   ["E", "Vampire"],
                   url: url,
                   time_limit_sec: 1
                 )
      end)
    end

    test "no known system means no request" do
      with_advertised(["E---3.5.1"], fn ->
        assert SystemOnTptp.query_selected_systems(
                 "fof(a, conjecture, p).",
                 ["Nope"],
                 url: "http://127.0.0.1:1/nowhere"
               ) == {:ok, [{"Nope", {:error, {:unknown_system, "Nope"}}}]}
      end)
    end
  end

  describe "query_system/3" do
    test "a name resolves before the request and the result names the version that ran" do
      url = start_canned_server(section("E---3.5.1", "Theorem"))

      with_advertised(["E---3.5.1"], fn ->
        assert {:ok, %Result{status: :theorem, system: "E---3.5.1"}} =
                 SystemOnTptp.query_system("fof(a, conjecture, p).", "E",
                   url: url,
                   time_limit_sec: 1
                 )
      end)

      assert_receive {:request, form}, 5_000
      assert form["System___E---3.5.1"] == "E---3.5.1"
    end

    test "an unknown system is refused without a request" do
      with_advertised(["E---3.5.1"], fn ->
        assert SystemOnTptp.query_system("fof(a, conjecture, p).", "Nope",
                 url: "http://127.0.0.1:1/nowhere"
               ) == {:error, {:unknown_system, "Nope"}}
      end)
    end

    test "query/2 runs the default system" do
      url = start_canned_server(section("E---3.5.1", "Theorem"))

      with_advertised(["E---3.5.1"], fn ->
        assert {:ok, %Result{system: "E---3.5.1"}} =
                 SystemOnTptp.query("fof(a, conjecture, p).", url: url, time_limit_sec: 1)
      end)
    end
  end
end
