defmodule AtpClient.StarExecTest do
  use ExUnit.Case, async: false

  alias AtpClient.StarExec
  alias AtpClient.StarExec.Session

  # A minimal HTTP/1.1 test server (no Plug dependency). Each accepted
  # connection is parsed into `{method, path, body}` and forwarded to the
  # supplied handler, whose return value is sent back as the response body
  # (with a fixed 200 OK envelope). Tests that need to assert what arrived
  # can also receive `{:request, method, path, body}` messages, which the
  # server delivers to the test process.
  defp start_server(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    parent = self()

    acceptor = spawn_link(fn -> accept_loop(listen, handler, parent) end)
    base_url = "http://127.0.0.1:#{port}"

    {base_url, listen, acceptor}
  end

  defp accept_loop(listen, handler, parent) do
    case :gen_tcp.accept(listen, 10_000) do
      {:ok, sock} ->
        spawn(fn -> handle_request(sock, handler, parent) end)
        accept_loop(listen, handler, parent)

      _ ->
        :ok
    end
  end

  defp handle_request(sock, handler, parent) do
    case read_request(sock) do
      {:ok, {method, path, headers, body}} ->
        send(parent, {:request, method, path, body})

        body_out = handler.({method, path, headers, body})
        ct = "application/json"

        response = [
          "HTTP/1.1 200 OK\r\n",
          "Content-Type: #{ct}\r\n",
          "Content-Length: #{byte_size(body_out)}\r\n",
          "Connection: close\r\n",
          "\r\n",
          body_out
        ]

        :gen_tcp.send(sock, response)
        :gen_tcp.close(sock)

      _ ->
        :gen_tcp.close(sock)
    end
  end

  defp read_request(sock) do
    :inet.setopts(sock, packet: :http_bin, active: false)

    with {:ok, {:http_request, method, uri, _ver}} <- :gen_tcp.recv(sock, 0, 5_000),
         {:ok, headers} <- read_headers(sock, []),
         path = path_from_uri(uri),
         length = content_length(headers),
         {:ok, body} <- read_body(sock, length) do
      {:ok, {to_string(method), path, headers, body}}
    end
  end

  defp read_headers(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        key = name |> to_string() |> String.downcase()
        read_headers(sock, [{key, to_string(value)} | acc])

      {:ok, :http_eoh} ->
        {:ok, Enum.reverse(acc)}

      err ->
        err
    end
  end

  defp content_length(headers) do
    case List.keyfind(headers, "content-length", 0) do
      {_, value} -> String.to_integer(value)
      _ -> 0
    end
  end

  defp read_body(_sock, 0), do: {:ok, ""}

  defp read_body(sock, n) do
    :inet.setopts(sock, packet: :raw, active: false)
    :gen_tcp.recv(sock, n, 2_000)
  end

  defp path_from_uri({:abs_path, path}), do: to_string(path)
  defp path_from_uri(other), do: to_string(other)

  defp session_for(base_url) do
    %Session{base_url: base_url, cookies: %{"JSESSIONID" => "test"}, opts: []}
  end

  describe "delete_job/3" do
    test "POSTs to /starexec/services/delete/job with selectedIds[]=<id>" do
      {base_url, _listen, _acceptor} = start_server(fn _ -> "{}" end)
      session = session_for(base_url)

      assert :ok = StarExec.delete_job(session, 7)

      assert_receive {:request, "POST", path, body}, 5_000
      assert path == "/starexec/services/delete/job"
      assert body =~ "selectedIds%5B%5D=7"
    end

    test "honours :delete_job_path override" do
      {base_url, _listen, _acceptor} = start_server(fn _ -> "{}" end)
      session = session_for(base_url)

      assert :ok =
               StarExec.delete_job(session, 42, delete_job_path: "/custom/delete")

      assert_receive {:request, "POST", "/custom/delete", _}, 5_000
    end
  end

  describe "wait_for_job/3 cancellation" do
    test "killing the calling Task fires delete_job for the in-flight job" do
      {base_url, _listen, _acceptor} =
        start_server(fn
          {"GET", "/starexec/services/details/job/" <> _id, _h, _b} ->
            # "Still running": completeTime is null.
            ~s({"completeTime":null,"jobName":"x"})

          {"POST", _path, _h, _b} ->
            "{}"
        end)

      session = session_for(base_url)
      parent = self()

      runner =
        spawn(fn ->
          send(parent, {:started, self()})

          StarExec.wait_for_job(session, 1234,
            poll_interval_ms: 50,
            timeout_ms: 60_000
          )
        end)

      assert_receive {:started, ^runner}, 1_000

      # Wait until at least one poll request hits the server, so the guard
      # is fully installed before we kill the caller.
      assert_receive {:request, "GET", "/starexec/services/details/job/1234", _}, 5_000

      Process.exit(runner, :kill)

      assert_receive {:request, "POST", "/starexec/services/delete/job", body}, 5_000
      assert body =~ "selectedIds%5B%5D=1234"
    end

    test "caller dies after the job already completed → no delete_job" do
      job_done = ~s({"completeTime":"2026-06-22T10:00:00","jobName":"x"})

      {base_url, _listen, _acceptor} =
        start_server(fn
          {"GET", "/starexec/services/details/job/" <> _id, _h, _b} -> job_done
          {"POST", _path, _h, _b} -> "{}"
        end)

      session = session_for(base_url)

      # Run wait_for_job to completion, then kill the calling process. The
      # guard should have been released by the time wait_for_job returned,
      # so the post-return Process.exit must NOT trigger a delete.
      parent = self()

      runner =
        spawn(fn ->
          {:ok, info} =
            StarExec.wait_for_job(session, 99,
              poll_interval_ms: 50,
              timeout_ms: 60_000
            )

          send(parent, {:done, info})
          # Block so we can kill the runner *after* wait_for_job returned.
          Process.sleep(:infinity)
        end)

      assert_receive {:done, %{"completeTime" => _}}, 5_000

      # Drain the GET that drove wait_for_job to completion.
      assert_receive {:request, "GET", _, _}, 1_000

      Process.exit(runner, :kill)

      # No further request should arrive — no delete_job after natural
      # completion.
      refute_receive {:request, _, _, _}, 500
    end
  end
end
