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

    * Tomcat form-based authentication at `/starexec/j_security_check`
      with the `j_username` and `j_password` fields;
    * A JSON job endpoint at `/services/details/job/{job_id}` returning the
      Gson form of `org.starexec.data.to.Job` (used to detect completion);
    * A ZIP download of all pair stdouts at
      `/secure/download?type=j_outputs&id={job_id}`.

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
        base_url: "https://starexec.example.org",
        username: "me",
        password: System.get_env("STAREXEC_PASS")
  """

  @behaviour AtpClient.Backend

  alias AtpClient.Config
  alias AtpClient.Config.Field
  alias AtpClient.ResultNormalization
  alias AtpClient.StarExec.Session

  @type job_id :: non_neg_integer() | String.t()
  @type benchmark_id :: pos_integer()
  @type space_id :: pos_integer()

  @impl AtpClient.Backend
  def config_key, do: :starexec

  @impl AtpClient.Backend
  def label, do: "StarExec"

  @impl AtpClient.Backend
  def config_schema do
    [
      %Field{
        key: :base_url,
        type: :string,
        required?: true,
        group: :connection,
        label: "Base URL",
        doc: "Scheme and host only — /starexec context is added by the library."
      },
      %Field{
        key: :username,
        type: :string,
        required?: true,
        group: :connection,
        label: "Username"
      },
      %Field{
        key: :password,
        type: :string,
        required?: true,
        group: :connection,
        secret?: true,
        label: "Password"
      },
      %Field{
        key: :space_id,
        type: :integer,
        required?: false,
        group: :defaults,
        label: "Default space ID"
      },
      %Field{
        key: :solver_cfg_id,
        type: :integer,
        required?: false,
        group: :defaults,
        label: "Default solver configuration ID"
      },
      %Field{
        key: :queue_id,
        type: :integer,
        required?: false,
        group: :defaults,
        default: 1,
        label: "Queue ID"
      },
      %Field{
        key: :cpu_timeout_s,
        type: :integer,
        required?: false,
        group: :defaults,
        default: 60,
        label: "CPU timeout (s)"
      }
    ]
  end

  @impl AtpClient.Backend
  def verify(opts \\ []) do
    with {:ok, session} <- login(opts) do
      logout(session, opts)
    end
  end

  @impl AtpClient.Backend
  @spec query(String.t(), keyword()) ::
          ResultNormalization.atp_result() | {:error, term()}
  def query(problem, opts \\ []) when is_binary(problem) do
    case login(opts) do
      {:ok, session} ->
        try do
          prove(session, problem, opts)
        after
          logout(session, opts)
        end

      {:error, _} = err ->
        err
    end
  end

  # Keys consumed by this module's own configuration / call-time API. They
  # must be stripped from the keyword list before it is handed to
  # `Req.request/1`, which validates options and rejects unknown ones.
  @starexec_only_opts [
    :username,
    :password,
    :request_timeout_ms,
    :poll_interval_ms,
    :session_init_path,
    :login_path,
    :logout_path,
    :job_info_path,
    :job_output_path,
    :create_job_path,
    :delete_job_path,
    :upload_benchmarks_path,
    :list_space_benchmarks_path,
    :benchmark_type,
    :queue_id,
    :cpu_timeout_s,
    :wallclock_timeout_s,
    :space_id,
    :solver_cfg_id,
    :timeout_ms,
    :complete_fun,
    :path
  ]

  @doc """
  Authenticates against the configured StarExec instance and returns a
  `Session` holding the session cookies needed for subsequent requests.

  ## Options

    * `:base_url`, `:username`, `:password` — override configuration;
    * `:login_path` — override the auth endpoint (default
      `/starexec/j_security_check`);
    * `:request_timeout_ms`.
  """
  @spec login(keyword()) :: {:ok, Session.t()} | {:error, term()}
  def login(opts \\ []) do
    base_url = Config.fetch!(:starexec, :base_url, opts)
    username = Config.fetch!(:starexec, :username, opts)
    password = Config.fetch!(:starexec, :password, opts)
    login_path = Config.fetch(:starexec, :login_path, "/starexec/j_security_check", opts)
    init_path = Config.fetch(:starexec, :session_init_path, "/starexec/secure/index.jsp", opts)
    timeout_ms = Config.fetch(:starexec, :request_timeout_ms, 30_000, opts)
    connect_options = Config.fetch(:starexec, :connect_options, [], opts)
    retry = Config.fetch(:starexec, :retry, :safe_transient, opts)

    base_req =
      Req.new(
        base_url: base_url,
        receive_timeout: timeout_ms,
        redirect: false,
        connect_options: connect_options,
        retry: retry
      )

    with {:ok, %{headers: init_headers}} <- Req.get(base_req, url: init_path) do
      initial_jar = extract_cookies(init_headers)

      body = URI.encode_query(%{"j_username" => username, "j_password" => password})

      post_opts =
        [
          url: login_path,
          body: body,
          headers: [{"content-type", "application/x-www-form-urlencoded"}]
        ]
        |> put_cookie_header(initial_jar)

      case Req.post(base_req, post_opts) do
        {:ok, %{status: status, headers: headers}} when status in [200, 302, 303] ->
          build_session(
            base_url,
            opts,
            connect_options,
            Map.merge(initial_jar, extract_cookies(headers))
          )

        {:ok, %{status: status}} ->
          {:error, {:login_failed, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_session(_base_url, _opts, _connect_options, jar) when map_size(jar) == 0 do
    {:error, :login_failed}
  end

  defp build_session(base_url, opts, connect_options, jar) do
    resolved_opts =
      opts
      |> Keyword.drop([:password])
      |> Keyword.put(:connect_options, connect_options)

    {:ok, %Session{base_url: base_url, cookies: jar, opts: resolved_opts}}
  end

  @doc """
  Terminates a StarExec session. Errors during logout are returned but are
  usually safe to ignore.
  """
  @spec logout(Session.t(), keyword()) :: :ok | {:error, term()}
  def logout(%Session{} = session, opts \\ []) do
    path = Config.fetch(:starexec, :logout_path, "/starexec/services/session/logout", opts)

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
    base = Config.fetch(:starexec, :job_info_path, "/starexec/services/details/job", opts)
    path = "#{base}/#{job_id}"

    case request(session, :get, path, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, decode(body)}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      other -> other
    end
  end

  @doc """
  Downloads the per-pair stdout archive ("j_outputs") for a finished job.
  StarExec has no JSON endpoint that returns a single pair's stdout in
  isolation; the official `StarexecCommand` CLI uses this download path
  instead, and it works without knowing the pair ids.

  Returns the raw ZIP bytes. Use `:zip.extract(bytes, [:memory])` (Erlang
  stdlib) to read the individual stdout files out of the archive.
  """
  @spec get_job_output(Session.t(), job_id(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def get_job_output(%Session{} = session, job_id, opts \\ []) do
    base = Config.fetch(:starexec, :job_output_path, "/starexec/secure/download", opts)
    path = "#{base}?type=j_outputs&id=#{job_id}"

    case request(session, :get, path, opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
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
    path =
      Keyword.get(opts, :path) ||
        Config.fetch(:starexec, :create_job_path, "/starexec/secure/add/job", opts)

    body = URI.encode_query(fields)

    request(
      session,
      :post,
      path,
      Keyword.merge(opts,
        body: body,
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        # StarExec replies to a successful job creation with a 302 redirect
        # whose Location carries the new job id. Following the redirect would
        # turn that into a 200 against the job-detail page and discard the
        # Location header.
        redirect: false
      )
    )
  end

  @doc """
  Uploads a single TPTP problem to a StarExec space.

  StarExec accepts only archives (.zip / .tar / .tgz) at the benchmark upload
  endpoint, so this function wraps `problem_text` in an in-memory ZIP whose
  sole entry is the new benchmark file. The benchmark's name inside StarExec
  becomes the entry's filename.

  The upload is processed asynchronously on the server, so this function
  returns as soon as the request is accepted. Use `wait_for_benchmark/4`
  (or `prove/3`, which composes both) to obtain the new benchmark id once
  StarExec has finished extracting and validating it.

  ## Options

    * `:name` — base name (without `.p`) for the uploaded file. Defaults to
      a random UUID-ish string so concurrent uploads don't collide.
    * `:benchmark_type` — benchmark processor id. Defaults to `1`
      (StarExec's "no type" processor), which accepts any text.
    * `:request_timeout_ms`.
  """
  @spec upload_benchmark(Session.t(), space_id(), binary(), keyword()) ::
          {:ok, %{name: String.t(), status_id: pos_integer() | nil}} | {:error, term()}
  def upload_benchmark(%Session{} = session, space_id, problem_text, opts \\ [])
      when is_integer(space_id) and is_binary(problem_text) do
    path =
      Config.fetch(
        :starexec,
        :upload_benchmarks_path,
        "/starexec/secure/upload/benchmarks",
        opts
      )

    benchmark_type = Config.fetch(:starexec, :benchmark_type, 1, opts)
    name = Keyword.get(opts, :name) || random_benchmark_name()
    file_name = name <> ".p"

    {:ok, {_zip_name, zip_bytes}} =
      :zip.create(~c"bench.zip", [{String.to_charlist(file_name), problem_text}], [:memory])

    fields = [
      space: to_string(space_id),
      upMethod: "dump",
      benchType: to_string(benchmark_type),
      download: "false",
      localOrURLOrGit: "local",
      dependency: "false",
      depRoot: "-1",
      benchFile: {zip_bytes, filename: "bench.zip", content_type: "application/zip"}
    ]

    upload_opts =
      opts
      |> Keyword.put(:form_multipart, fields)
      # StarExec replies with a 302 to secure/details/uploadStatus.jsp?id=N.
      # Following would mask the Location and discard the status id.
      |> Keyword.put(:redirect, false)

    case request(session, :post, path, upload_opts) do
      {:ok, %{status: status} = resp} when status in [302, 303] ->
        {:ok, %{name: file_name, status_id: extract_status_id(resp)}}

      {:ok, %{status: status}} ->
        {:error, {:upload_failed, status}}

      other ->
        other
    end
  end

  @doc """
  Lists every benchmark in `space_id`.

  StarExec's REST surface for this is a DataTables-style endpoint that
  returns each row as `[anchor_html, type_html]`; this function parses the
  anchor to recover the structured `[%{id: …, name: …}]` we want.
  """
  @spec list_space_benchmarks(Session.t(), space_id(), keyword()) ::
          {:ok, [%{id: benchmark_id(), name: String.t()}]} | {:error, term()}
  def list_space_benchmarks(%Session{} = session, space_id, opts \\ [])
      when is_integer(space_id) do
    template =
      Config.fetch(
        :starexec,
        :list_space_benchmarks_path,
        "/starexec/services/job/{space_id}/allbench/pagination/",
        opts
      )

    path = String.replace(template, "{space_id}", to_string(space_id))

    form = [
      sEcho: "1",
      iColumns: "2",
      iDisplayStart: "0",
      iDisplayLength: "-1",
      iSortCol_0: "0",
      sSortDir_0: "asc",
      sSearch: ""
    ]

    list_opts = Keyword.put(opts, :form, form)

    case request(session, :post, path, list_opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_benchmark_rows(body)}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      other ->
        other
    end
  end

  @doc """
  Polls `list_space_benchmarks/3` until a benchmark named `name` appears, then
  returns its id. Fails with `{:error, :timeout}` if the benchmark has not
  appeared within `:timeout_ms` (default 60 s).
  """
  @spec wait_for_benchmark(Session.t(), space_id(), String.t(), keyword()) ::
          {:ok, benchmark_id()} | {:error, term()}
  def wait_for_benchmark(%Session{} = session, space_id, name, opts \\ [])
      when is_binary(name) do
    poll_ms = Config.fetch(:starexec, :poll_interval_ms, 2_000, opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_benchmark(session, space_id, name, poll_ms, deadline, opts)
  end

  defp do_wait_for_benchmark(session, space_id, name, poll_ms, deadline, opts) do
    case lookup_benchmark(session, space_id, name, opts) do
      {:ok, id} ->
        {:ok, id}

      :not_found ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(poll_ms)
          do_wait_for_benchmark(session, space_id, name, poll_ms, deadline, opts)
        end

      {:error, _} = err ->
        err
    end
  end

  defp lookup_benchmark(session, space_id, name, opts) do
    with {:ok, benches} <- list_space_benchmarks(session, space_id, opts) do
      case Enum.find(benches, &(&1.name == name)) do
        %{id: id} -> {:ok, id}
        nil -> :not_found
      end
    end
  end

  @doc """
  End-to-end: upload `problem_text` as a fresh benchmark, run it against the
  configured solver, wait for completion, and return the normalized result.

  This is the "single shot" entry point that mirrors the other backends'
  prove/2-style helpers. It is implemented purely in terms of the lower-level
  functions in this module, so anything it does can be done by hand for
  finer control.

  ## Required options

    * `:space_id` — target StarExec space (used for both the upload and the
      job).
    * `:solver_cfg_id` — solver *configuration* id (not solver id).

  ## Common options

    * `:queue_id` (default from config; `1` if unset) — worker queue id.
    * `:cpu_timeout_s` (default from config; `60` if unset).
    * `:wallclock_timeout_s` (default `cpu_timeout_s * 2`).
    * `:benchmark_type` (default `1`).
    * `:timeout_ms` — wall-clock budget for the whole pipeline; passed to
      both `wait_for_benchmark/4` and `wait_for_job/3`.

  All other StarExec options (`:base_url`, `:username`, `:password`, …) are
  consumed by `request/4` as usual.
  """
  @spec prove(Session.t(), binary(), keyword()) ::
          ResultNormalization.atp_result() | {:error, term()}
  def prove(%Session{} = session, problem_text, opts \\ []) when is_binary(problem_text) do
    space_id = Config.fetch!(:starexec, :space_id, opts)
    solver_cfg_id = Config.fetch!(:starexec, :solver_cfg_id, opts)
    queue_id = Config.fetch(:starexec, :queue_id, 1, opts)
    cpu_timeout_s = Config.fetch(:starexec, :cpu_timeout_s, 60, opts)
    wallclock_timeout_s = Keyword.get(opts, :wallclock_timeout_s, cpu_timeout_s * 2)

    with {:ok, %{name: bench_name}} <-
           upload_benchmark(session, space_id, problem_text, opts),
         {:ok, bench_id} <-
           wait_for_benchmark(session, space_id, bench_name, opts),
         {:ok, job_resp} <-
           create_job(
             session,
             prove_job_fields(
               space_id,
               queue_id,
               solver_cfg_id,
               bench_id,
               bench_name,
               cpu_timeout_s,
               wallclock_timeout_s
             ),
             opts
           ),
         {:ok, job_id} <- job_id_from_response(job_resp),
         {:ok, _job_info} <- wait_for_job(session, job_id, opts),
         {:ok, zip_bytes} <- get_job_output(session, job_id, opts),
         {:ok, stdout} <- single_stdout_from_zip(zip_bytes) do
      ResultNormalization.interpret_result(stdout)
    end
  end

  # --- prove/3 helpers --------------------------------------------------

  defp prove_job_fields(space_id, queue_id, solver_cfg_id, bench_id, bench_name, cpu_s, wall_s) do
    %{
      "sid" => to_string(space_id),
      "name" => "atp_client " <> bench_name,
      "desc" => "AtpClient.StarExec.prove/3",
      "queue" => to_string(queue_id),
      "benchmarkingFramework" => "RUNSOLVER",
      "seed" => "0",
      "preProcess" => "-1",
      "postProcess" => "-1",
      "cpuTimeout" => to_string(cpu_s),
      "wallclockTimeout" => to_string(wall_s),
      "maxMem" => "1.0",
      "runChoice" => "choose",
      "benchChoice" => "runChosenFromSpace",
      "bench" => to_string(bench_id),
      "configs" => to_string(solver_cfg_id),
      # CreateJob.java unconditionally dereferences `pause`; omitting it
      # produces an uncaught NPE (HTTP 500).
      "pause" => "no"
    }
  end

  defp job_id_from_response(%{status: status, headers: headers}) when status in [302, 303] do
    location = location_header(headers)

    case location && Regex.run(~r/[?&](?:job)?[Ii]d=(\d+)|\/jobs\/(\d+)/, location) do
      [_, id, ""] -> {:ok, String.to_integer(id)}
      [_, "", id] -> {:ok, String.to_integer(id)}
      [_, id] -> {:ok, String.to_integer(id)}
      _ -> {:error, {:no_job_id, location}}
    end
  end

  defp job_id_from_response(%{status: status}), do: {:error, {:create_job_failed, status}}

  # Pull the `Location` header off a response, regardless of case or whether
  # the HTTP client returned it as a bare string or a one-element list.
  defp location_header(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == "location", do: normalize_header_value(value)
    end)
  end

  defp normalize_header_value([value | _]), do: value
  defp normalize_header_value(value) when is_binary(value), do: value
  defp normalize_header_value(_), do: nil

  defp single_stdout_from_zip(zip_bytes) do
    with {:ok, entries} <- :zip.extract(zip_bytes, [:memory]) do
      files =
        Enum.filter(entries, fn
          {name, content} when is_binary(content) ->
            not String.ends_with?(to_string(name), "/")

          _ ->
            false
        end)

      case files do
        [{_name, content}] -> {:ok, content}
        [] -> {:error, :empty_job_output}
        many -> {:error, {:multiple_outputs, length(many)}}
      end
    end
  end

  # --- upload/list helpers ----------------------------------------------

  defp extract_status_id(%{headers: headers}) do
    case location_header(headers) do
      nil -> nil
      location -> parse_id_from_location(location)
    end
  end

  defp parse_id_from_location(loc) do
    case Regex.run(~r/[?&]id=(\d+)/, loc) do
      [_, id] -> String.to_integer(id)
      _ -> nil
    end
  end

  # The DataTables JSON has shape %{"aaData" => [["<a href=...>name</a>",
  # "<span>type</span>"], ...]}. We pull (id, name) out of the anchor.
  defp parse_benchmark_rows(body) do
    rows =
      body
      |> decode()
      |> Map.get("aaData", [])

    rows
    |> Enum.map(&parse_benchmark_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_benchmark_row([anchor | _]) when is_binary(anchor) do
    case Regex.run(~r/benchmark\.jsp\?id=(\d+)[^>]*>([^<]+)/s, anchor) do
      [_, id, name] -> %{id: String.to_integer(id), name: name}
      _ -> nil
    end
  end

  defp parse_benchmark_row(_), do: nil

  defp random_benchmark_name do
    # Unique enough for concurrent runs in the same space — 16 hex digits
    # of crypto-grade randomness, prefixed so the source is obvious in the
    # UI.
    "atp_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  @doc """
  Polls `get_job/3` until the returned JSON reports that the job is complete
  or the per-call `:timeout_ms` elapses.

  "Complete" is defined as a `completed` field equal to the `totalJobPairs`
  field (or a `jobComplete` flag being truthy). The exact JSON shape depends
  on the StarExec version; if it differs on your deployment, pass a custom
  predicate via `:complete_fun`, which receives the decoded job map and
  returns a boolean.

  ## Cancellation

  This call installs a small helper process that monitors the calling
  process. If the caller dies (`Process.exit`, `Task.shutdown`, …) while
  the job is still running, the helper issues `delete_job/3` so the remote
  StarExec job does not run to completion on the cluster. If the job has
  already reached a terminal state (`complete_fun.(info)` is true) by the
  time the caller dies, the `delete_job` request is skipped.
  """
  @spec wait_for_job(Session.t(), job_id(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def wait_for_job(%Session{} = session, job_id, opts \\ []) do
    poll_ms = Config.fetch(:starexec, :poll_interval_ms, 2_000, opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, 600_000)
    complete_fun = Keyword.get(opts, :complete_fun, &default_complete?/1)

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    {:ok, guard} = start_cancel_guard(session, job_id, opts)

    try do
      result = do_wait(session, job_id, poll_ms, deadline, complete_fun, opts)
      # Mark the job as "no longer cancellable" once it's reached a terminal
      # state (or we've given up locally). The guard will skip delete_job if
      # the caller dies after this point.
      release_cancel_guard(guard)
      result
    after
      stop_cancel_guard(guard)
    end
  end

  @doc """
  Asks the StarExec instance to delete the given job, freeing the remote
  compute slot. Used by `wait_for_job/3` and `prove/3` to release resources
  when the calling process is cancelled.

  StarExec's delete endpoint (`POST /starexec/services/delete/job`) expects
  the job id(s) in the `selectedIds[]` form field; the underlying servlet
  flips the `deleted` column synchronously and then queues the on-disk
  cleanup off-thread, so a 200 response is returned quickly even for large
  jobs.

  The endpoint path is configurable via `:delete_job_path` for older
  StarExec instances that mount it elsewhere.
  """
  @spec delete_job(Session.t(), job_id(), keyword()) :: :ok | {:error, term()}
  def delete_job(%Session{} = session, job_id, opts \\ []) do
    path = Config.fetch(:starexec, :delete_job_path, "/starexec/services/delete/job", opts)
    body = URI.encode_query([{"selectedIds[]", to_string(job_id)}])

    case request(
           session,
           :post,
           path,
           Keyword.merge(opts,
             body: body,
             headers: [{"content-type", "application/x-www-form-urlencoded"}]
           )
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:delete_failed, status}}
      other -> other
    end
  end

  # --- caller-cancel guard ----------------------------------------------

  # Starts a helper process that monitors the caller. If the caller dies
  # while the job is still considered cancellable, the helper issues
  # `delete_job/3`. The helper itself does not link to the caller, so the
  # caller's death does not propagate further than its mailbox.
  defp start_cancel_guard(session, job_id, opts) do
    caller = self()

    pid =
      spawn(fn ->
        ref = Process.monitor(caller)
        cancel_guard_loop(ref, session, job_id, opts, _armed? = true)
      end)

    {:ok, pid}
  end

  # Mark the guard disarmed (the job is finished, don't delete) but keep
  # it running until `stop_cancel_guard/1` so its mailbox is still drained.
  defp release_cancel_guard(pid), do: send(pid, :release)

  # Tell the guard we're done; it exits without firing delete_job.
  defp stop_cancel_guard(pid), do: send(pid, :stop)

  defp cancel_guard_loop(ref, session, job_id, opts, armed?) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        if armed?, do: _ = delete_job(session, job_id, opts)
        :ok

      :release ->
        cancel_guard_loop(ref, session, job_id, opts, false)

      :stop ->
        Process.demonitor(ref, [:flush])
        :ok
    end
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

  # The Job DTO returned by /services/details/job/{id} is the Gson form of
  # `org.starexec.data.to.Job`. Its `completeTime` field is null until every
  # pair has finished, at which point Gson stamps an ISO-8601 string. Default
  # Gson omits null fields, so "completeTime" being present at all is enough.
  defp default_complete?(%{"completeTime" => t}) when is_binary(t) and t != "", do: true
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
      session.opts
      |> Keyword.merge(opts)
      |> Keyword.drop(@starexec_only_opts)
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
    |> Enum.flat_map(fn {key, value} ->
      if String.downcase(key) == "set-cookie", do: List.wrap(value), else: []
    end)
    |> Enum.reduce(%{}, &raw_cookie_reduce/2)
  end

  defp raw_cookie_reduce(raw, acc) do
    [kv | _] = String.split(raw, ";", parts: 2)

    case String.split(kv, "=", parts: 2) do
      [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
      _ -> acc
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
