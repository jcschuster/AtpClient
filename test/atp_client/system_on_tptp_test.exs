defmodule AtpClient.SystemOnTptpTest do
  use ExUnit.Case, async: false

  alias AtpClient.Result
  alias AtpClient.SystemOnTptp
  alias AtpClient.SystemOnTptp.Systems

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
    previous = Agent.get(Systems, & &1)

    records =
      Enum.map(
        systems,
        &%AtpClient.System{id: &1, name: AtpClient.System.name(&1), interfaces: [:system_on_tptp]}
      )

    Agent.update(Systems, fn state -> %{state | systems: records} end)

    try do
      fun.()
    after
      Agent.update(Systems, fn _ -> previous end)
    end
  end

  @rule "%" <> String.duplicate("-", 78) <> "\n"

  # A section in the shape of an `X2TPTP=-S` reply, as in
  # test/fixtures/sotp_x2tptp_e_vampire.txt.
  defp section(id, status) do
    @rule <>
      "% File     : #{id}\n% Problem  : SOT_x : v?.?.?\n% Result   : #{status} 0.00s 0.03s\n" <>
      @rule <>
      @rule <> "%----ORIGINAL SYSTEM OUTPUT\n% % SZS status #{status} for SOT_x\n" <> @rule
  end

  describe "query_selected_systems/3" do
    test "resolves names, keeps unknown systems out of the request, and reports every system given" do
      reply =
        section("E---3.5.1", "Theorem") <> section("Vampire---5.0.1", "Theorem")

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
        section("Vampire---5.0.1", "Theorem") <> section("E---3.5.1", "Theorem")

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

  # The records of the 2026-10-14 report, for the interface checks and the
  # systems' own Solved patterns.
  @report_systems (
                    {:ok, systems, _} =
                      AtpClient.SystemOnTptp.SystemInfo.parse(
                        File.read!("test/fixtures/system_info_2026-10-14.txt")
                      )

                    systems
                  )

  defp with_report(fun) do
    previous = Agent.get(Systems, & &1)
    Agent.update(Systems, fn state -> %{state | systems: @report_systems} end)

    try do
      fun.()
    after
      Agent.update(Systems, fn _ -> previous end)
    end
  end

  describe "systems/1" do
    test "dialect: names the systems whose SPCs name it, whatever the other components" do
      with_report(fn ->
        ids = Enum.map(SystemOnTptp.systems(dialect: :th1), & &1.id)

        # Vampire's TH1_NAR counts; E's TH0_NAR does not make it TH1.
        assert "Vampire---5.0.1" in ids
        refute "E---3.5.1" in ids
        assert length(ids) == 14

        assert "E---3.5.1" in Enum.map(SystemOnTptp.systems(dialect: :th0), & &1.id)
        assert SystemOnTptp.systems(dialect: :tcf) == []

        # spc: stays an exact word: E lists TH0_NAR, not TH0.
        refute "E---3.5.1" in Enum.map(SystemOnTptp.systems(spc: "TH0"), & &1.id)
      end)
    end
  end

  describe "the reply shapes" do
    test "X2TPTP=-S is sent by default and not with x2tptp: false" do
      url = start_canned_server(File.read!("test/fixtures/sotp_x2tptp_e_vampire.txt"))

      with_report(fn ->
        assert {:ok, %Result{status: :theorem, details: %{tstp: %Tptp.Tstp.Solution{}}}} =
                 SystemOnTptp.query_system("fof(c, conjecture, q).", "E",
                   url: url,
                   time_limit_sec: 1
                 )
      end)

      assert_receive {:request, %{"X2TPTP" => "-S"}}, 5_000

      url = start_canned_server(File.read!("test/fixtures/sotp_raw_e_vampire.txt"))

      with_report(fn ->
        assert {:ok, %Result{status: :theorem, details: %{}}} =
                 SystemOnTptp.query_system("fof(c, conjecture, q).", "E",
                   url: url,
                   time_limit_sec: 1,
                   x2tptp: false
                 )
      end)

      assert_receive {:request, form}, 5_000
      refute Map.has_key?(form, "X2TPTP")
    end

    test "a raw reply's sections are named by % RESULT:, in the order given" do
      url = start_canned_server(File.read!("test/fixtures/sotp_raw_inappropriate.txt"))

      with_report(fn ->
        assert {:ok, [{"Satallax---3.5", {:ok, satallax}}, {"Twee---2.7", {:ok, twee}}]} =
                 SystemOnTptp.query_selected_systems(
                   "fof(c, conjecture, q).",
                   ["Satallax", "Twee"],
                   url: url,
                   time_limit_sec: 1,
                   x2tptp: false
                 )

        assert satallax.status == :inappropriate
        assert twee.status == :theorem
      end)
    end
  end

  describe "process_problem/3 and process_solution/3" do
    test "ECNF through ProcessProblem: a Success with a ListOfCNF block" do
      url = start_canned_server(File.read!("test/fixtures/ecnf_process_problem.txt"))

      with_report(fn ->
        assert {:ok, %Result{status: :success, system: "ECNF---3.5.1"} = result} =
                 SystemOnTptp.process_problem("fof(c, conjecture, q).", "ECNF",
                   url: url,
                   time_limit_sec: 1
                 )

        assert {:ok, %Tptp.File{statements: [_, _, _]}, []} = Result.formulae(result)
      end)

      assert_receive {:request, form}, 5_000
      assert form["SubmitButton"] == "ProcessProblem"
      assert form["InputFormat"] == "TPTP"
      refute Map.has_key?(form, "X2TPTP")
    end

    test "GDV through ProcessSolution: VerifiedGood, and GaveUp on a syntax error" do
      url = start_canned_server(File.read!("test/fixtures/gdv_verified_good.txt"))

      with_report(fn ->
        assert {:ok, %Result{status: :verified_good} = result} =
                 SystemOnTptp.process_solution("cnf(c, plain, $false).", "GDV",
                   url: url,
                   time_limit_sec: 1
                 )

        assert Result.success?(result)
      end)

      assert_receive {:request, form}, 5_000
      assert form["SubmitButton"] == "ProcessSolution"
      assert form["SolutionFormat"] == "TPTP"

      url = start_canned_server(File.read!("test/fixtures/gdv_syntax_error.txt"))

      with_report(fn ->
        assert {:ok, %Result{status: :gave_up}} =
                 SystemOnTptp.process_solution("fof(a,axiom,p(.", "GDV",
                   url: url,
                   time_limit_sec: 1
                 )
      end)
    end

    test "AGMV's Verified is read through its own Solved pattern" do
      reply =
        "% START OF SYSTEM OUTPUT\n% SZS status Verified for SOT_x\n% END OF SYSTEM OUTPUT\n" <>
          "% RESULT: SOT_x - AGMV---1.0 says Verified - CPU = 0.00\n"

      url = start_canned_server(reply)

      with_report(fn ->
        assert {:ok,
                %Result{status: :verified_good, evidence: {:system_info, "VerifiedGood"}} = result} =
                 SystemOnTptp.process_solution("fof(m, interpretation, $true).", "AGMV",
                   url: url,
                   time_limit_sec: 1
                 )

        assert Result.success?(result)
      end)
    end

    test "each entry point checks the system's interfaces before any round-trip" do
      with_report(fn ->
        assert {:error, {:not_offered, "GDV---2.0", :system_on_tptp}} =
                 SystemOnTptp.query_system("p.", "GDV", url: "http://127.0.0.1:1/x")

        assert {:error, {:not_offered, "E---3.5.1", :system_b4_tptp}} =
                 SystemOnTptp.process_problem("p.", "E", url: "http://127.0.0.1:1/x")

        assert {:error, {:not_offered, "E---3.5.1", :system_on_tstp}} =
                 SystemOnTptp.process_solution("p.", "E", url: "http://127.0.0.1:1/x")

        assert {:ok, [{"GDV---2.0", {:error, {:not_offered, "GDV---2.0", :system_on_tptp}}}]} =
                 SystemOnTptp.query_selected_systems("p.", ["GDV"], url: "http://127.0.0.1:1/x")
      end)
    end
  end

  describe "AtpClient.verify/2" do
    test "a result's derivation goes to GDV" do
      [{id, text}, _] =
        SystemOnTptp.Reply.sections(File.read!("test/fixtures/sotp_x2tptp_e_vampire.txt"))

      {:ok, proved} = SystemOnTptp.read_section(id, text)
      url = start_canned_server(File.read!("test/fixtures/gdv_verified_good.txt"))

      with_report(fn ->
        assert {:ok, %Result{status: :verified_good}} =
                 AtpClient.verify(proved, url: url, time_limit_sec: 1)
      end)

      assert_receive {:request, form}, 5_000
      assert form["System___GDV---2.0"] == "GDV---2.0"
      assert form["FORMULAEProblem"] =~ "c_0_10"
    end

    test "an interpretation goes to AGMV, and with: picks another verifier" do
      {:ok, file, []} = Tptp.from_string(~s|fof(m, interpretation, ! [X] : X = "d0" & p("d0")).|)
      {:ok, model} = AtpClient.Interpretation.from_file(file)
      url = start_canned_server("% SZS status VerifiedGood\n")

      with_report(fn -> AtpClient.verify(model, url: url, time_limit_sec: 1) end)
      assert_receive {:request, %{"System___AGMV---1.0" => "AGMV---1.0"}}, 5_000

      url = start_canned_server("% SZS status VerifiedGood\n")
      with_report(fn -> AtpClient.verify(model, with: "GDV", url: url, time_limit_sec: 1) end)
      assert_receive {:request, %{"System___GDV---2.0" => "GDV---2.0"}}, 5_000
    end

    test "a result with nothing to verify" do
      {:ok, result} = AtpClient.Verdict.interpret("% SZS status Theorem\n", AtpClient.LocalExec)
      assert AtpClient.verify(result) == {:error, :nothing_to_verify}
    end
  end
end
