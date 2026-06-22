defmodule AtpClient.SystemOnTptpTest do
  use ExUnit.Case, async: false

  alias AtpClient.SystemOnTptp

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
      result =
        SystemOnTptp.query_system(
          "fof(a, conjecture, p).",
          "Vampire-FMo---5.0.1",
          url: url,
          time_limit_sec: 0
        )

      assert match?({:error, _}, result),
             "expected {:error, _} from the fake server but got #{inspect(result)}"

      :gen_tcp.close(listen)
    end
  end
end
