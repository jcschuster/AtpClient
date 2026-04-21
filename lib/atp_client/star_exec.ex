defmodule AtpClient.StarExec do
  @moduledoc """
  Client for self-hosted StarExec instances.

  StarExec is primarily a web application backed by Tomcat, and its
  programmatic surface is the same set of URLs that the web UI talks to.
  This module authenticates against that surface and exposes the subset of
  operations needed to submit benchmarks to pre-configured solvers, poll for
  completion, and fetch solver output.

  ## Assumptions

  The standard StarExec deployment exposes:

    * Tomcat form-based authentication at `/j_security_check` with the
      `j_username` and `j_password` fields;
    * A JSON job endpoint at `/services/jobs/{job_id}`;
    * Solver output at `/services/jobs/pairs/{pair_id}/stdout`.

  All of these paths are configurable; see `AtpClient.Config`.

  Because StarExec's job-creation form accepts a large number of fields and
  the exact set varies by release, `create_job/3` is kept minimal and
  deliberately flexible — consumers pass the multipart form fields their
  instance expects, and this module handles authentication and session
  cookies around the call.

  ## Example

      iex> {:ok, session} = AtpClient.StarExec.login()
      iex> {:ok, job_info} = AtpClient.StarExec.get_job(session, 1234)
      iex> :ok = AtpClient.StarExec.logout(session)

  ## Configuration

      config :atp_client, :starexec,
        base_url: "https://starexec.example.org/starexec",
        username: "me",
        password: System.get_env("STAREXEC_PASS")
  """

  alias AtpClient.Config
  alias AtpClient.StarExec.Session

  @type job_id :: non_neg_integer() | String.t()
  @type pair_id :: non_neg_integer() | String.t()

  @doc """
  Authenticates against the configured StarExec instance and returns a
  `Session` holding the session cookies needed for subsequent requests.

  ## Options

    * `:base_url`, `:username`, `:password` — override configuration;
    * `:login_path` — override the auth endpoint (default `/j_security_check`);
    * `:request_timeout_ms`.
  """
  @spec login(keyword()) :: {:ok, Session.t()} | {:error, term()}
  def login(opts \\ []) do
    base_url = Config.fetch!(:starexec, :base_url, opts)
    username = Config.fetch!(:starexec, :username, opts)
    password = Config.fetch!(:starexec, :password, opts)
    login_path = Config.fetch(:starexec, :login_path, "/j_security_check", opts)
    timeout_ms = Config.fetch(:starexec, :request_timeout_ms, 30_000, opts)

    body =
      URI.encode_query(%{
        "j_username" => username,
        "j_password" => password
      })

    # `redirect: false` is important: Tomcat form auth responds with 302 on
    # success, and we want the cookie jar rather than a rendered page.
    request =
      Req.new(
        base_url: base_url,
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        receive_timeout: timeout_ms,
        redirect: false
      )

    case Req.post(request, url: login_path, body: body) do
      {:ok, %{status: status, headers: headers}} when status in [200, 302, 303] ->
        case extract_cookies(headers) do
          %{} = jar when map_size(jar) > 0 ->
            {:ok,
             %Session{
               base_url: base_url,
               cookies: jar,
               opts: Keyword.drop(opts, [:password])
             }}

          _empty ->
            # Some deployments return 200 on a failed login with an empty jar;
            # flag that explicitly rather than returning an unusable session.
            {:error, :login_failed}
        end

      {:ok, %{status: status}} ->
        {:error, {:login_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Terminates a StarExec session. Errors during logout are returned but are
  usually safe to ignore.
  """
  @spec logout(Session.t(), keyword()) :: :ok | {:error, term()}
  def logout(%Session{} = session, opts \\ []) do
    path = Config.fetch(:starexec, :logout_path, "/services/session/logout", opts)

    case request(session, :post, path, opts) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:logout_failed, status}}
      other -> other
    end
  end

  @doc """
  Retrieves the JSON status of a StarExec job.
  """
  @spec get_job(Session.t(), job_id(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_job(%Session{} = session, job_id, opts \\ []) do
    base = Config.fetch(:starexec, :job_info_path, "/services/jobs", opts)
    path = "#{base}/#{job_id}"

    case request(session, :get, path, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, decode(body)}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      other -> other
    end
  end

  @doc """
  Fetches the plain stdout of a single job pair. StarExec represents each
  (benchmark, solver, config) tuple within a job as a "pair"; this function
  retrieves the raw solver output for a pair, which can then be passed to
  `AtpClient.ResultNormalization.interpret_result/1`.
  """
  @spec get_pair_stdout(Session.t(), pair_id(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def get_pair_stdout(%Session{} = session, pair_id, opts \\ []) do
    base = Config.fetch(:starexec, :pair_stdout_path, "/services/jobs/pairs", opts)
    path = "#{base}/#{pair_id}/stdout"

    case request(session, :get, path, opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} -> {:ok, to_string(body)}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      other -> other
    end
  end

  @doc """
  Creates a new StarExec job. The `fields` map is sent as the form body and
  must contain everything the deployment's `/secure/add/job` handler expects.

  A typical field set includes `"name"`, `"desc"`, `"queue"`, `"sid"` (space
  id), `"cpuTimeout"`, `"wallclockTimeout"`, `"benchProcess"`, `"traversal"`,
  plus any solver/benchmark selection fields. Refer to your StarExec
  instance's form for the authoritative list.

  Returns the raw response so the caller can extract the redirect/location
  that typically contains the new job id.
  """
  @spec create_job(Session.t(), map(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def create_job(%Session{} = session, fields, opts \\ []) when is_map(fields) do
    path = Keyword.get(opts, :path, "/secure/add/job")
    body = URI.encode_query(fields)

    request(
      session,
      :post,
      path,
      Keyword.merge(opts,
        body: body,
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      )
    )
  end

  @doc """
  Polls `get_job/3` until the returned JSON reports that the job is complete
  or the per-call `:timeout_ms` elapses.

  "Complete" is defined as a `completed` field equal to the `totalJobPairs`
  field (or a `jobComplete` flag being truthy). The exact JSON shape depends
  on the StarExec version; if it differs on your deployment, pass a custom
  predicate via `:complete_fun`, which receives the decoded job map and
  returns a boolean.
  """
  @spec wait_for_job(Session.t(), job_id(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def wait_for_job(%Session{} = session, job_id, opts \\ []) do
    poll_ms = Config.fetch(:starexec, :poll_interval_ms, 2_000, opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, 600_000)
    complete_fun = Keyword.get(opts, :complete_fun, &default_complete?/1)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(session, job_id, poll_ms, deadline, complete_fun, opts)
  end

  defp do_wait(session, job_id, poll_ms, deadline, complete_fun, opts) do
    case get_job(session, job_id, opts) do
      {:ok, info} ->
        cond do
          complete_fun.(info) ->
            {:ok, info}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, :timeout}

          true ->
            Process.sleep(poll_ms)
            do_wait(session, job_id, poll_ms, deadline, complete_fun, opts)
        end

      {:error, _} = err ->
        err
    end
  end

  defp default_complete?(%{"jobComplete" => true}), do: true

  defp default_complete?(%{"completed" => c, "totalJobPairs" => t})
       when is_integer(c) and is_integer(t) and t > 0,
       do: c >= t

  defp default_complete?(_), do: false

  @doc """
  Low-level helper: issue an HTTP request against `session.base_url` carrying
  the session cookies. Consumers can use this to reach StarExec endpoints
  that are not yet wrapped by this module.

  Supported options include anything `Req.request/1` accepts, plus
  `:request_timeout_ms` which is translated to `:receive_timeout`.
  """
  @spec request(Session.t(), atom(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def request(%Session{} = session, method, path, opts \\ []) do
    timeout_ms =
      Keyword.get(opts, :request_timeout_ms) ||
        Config.fetch(:starexec, :request_timeout_ms, 30_000)

    req_opts =
      opts
      |> Keyword.drop([:request_timeout_ms])
      |> Keyword.merge(
        method: method,
        base_url: session.base_url,
        url: path,
        receive_timeout: timeout_ms
      )
      |> put_cookie_header(session.cookies)

    Req.request(req_opts)
  end

  # --- internal helpers -------------------------------------------------

  defp put_cookie_header(req_opts, cookies) when cookies == %{} do
    req_opts
  end

  defp put_cookie_header(req_opts, cookies) do
    cookie_header =
      cookies
      |> Enum.map_join("; ", fn {k, v} -> "#{k}=#{v}" end)

    headers = Keyword.get(req_opts, :headers, [])

    merged_headers =
      case Enum.find_index(headers, fn {k, _} ->
             String.downcase(k) == "cookie"
           end) do
        nil -> [{"cookie", cookie_header} | headers]
        idx -> List.replace_at(headers, idx, {"cookie", cookie_header})
      end

    Keyword.put(req_opts, :headers, merged_headers)
  end

  defp extract_cookies(headers) do
    headers
    |> Enum.flat_map(fn
      {"set-cookie", v} -> List.wrap(v)
      {"Set-Cookie", v} -> List.wrap(v)
      _ -> []
    end)
    |> Enum.reduce(%{}, &raw_cookie_reduce/2)
  end

  defp raw_cookie_reduce(raw, acc) do
    case String.split(raw, ";", parts: 2) do
      [kv | _] ->
        case String.split(kv, "=", parts: 2) do
          [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
          _ -> acc
        end

      _ ->
        acc
    end
  end

  defp decode(body) when is_map(body) or is_list(body), do: body

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{"raw" => body}
    end
  end
end
