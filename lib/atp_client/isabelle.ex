defmodule AtpClient.Isabelle do
  @moduledoc """
  Client for Isabelle servers, built on top of `IsabelleClientMini` from the
  `:isabelle_elixir` package.

  The Isabelle server cannot accept theory text over the wire — theories have
  to live as `.thy` files on a filesystem that both the BEAM node running
  AtpClient and the Isabelle server can see. This module handles the file
  bookkeeping for you: you pass the theory body as a string, and it is
  written into a configured shared directory before `use_theories` is
  invoked.

  ## Configuration

      config :atp_client, :isabelle,
        host: "isabelle.example.org",
        port: 9999,
        password: System.get_env("ISABELLE_PASSWORD"),
        # Where AtpClient writes .thy files (as seen by this BEAM node):
        local_dir: "/shared/problems",
        # Where those same files appear on the Isabelle side (may differ in
        # containerised setups; defaults to `local_dir` when unset):
        isabelle_dir: "/shared/problems",
        session: "HOL"

  ### Paths: `local_dir` vs. `isabelle_dir`

  The Isabelle server wants a filesystem path it can resolve in **its own**
  view of the world. When the BEAM and the Isabelle server see the same
  directory under the same path, only `local_dir` is needed — this module
  expands it to an absolute path and passes it to Isabelle as `master_dir`.

  When the two views differ, you must set `isabelle_dir` explicitly. The two
  common cases:

    * **Containers:** BEAM writes to `/shared/problems` inside its container;
      the Isabelle server container has the same volume mounted at
      `/data/problems`. Set `local_dir: "/shared/problems"` and
      `isabelle_dir: "/data/problems"`.
    * **Windows + Cygwin:** BEAM on Windows sees `C:/Users/you/thy`;
      Isabelle started from a Cygwin shell sees the same directory as
      `/cygdrive/c/Users/you/thy`. Set both accordingly.

  Paths given via `isabelle_dir` are passed through verbatim — the library
  does not try to translate Windows paths to POSIX or vice-versa.

  ## Example

      theory = ~S\"\"\"
      theory Example imports Main begin
      lemma "P \\<or> \\<not> P" by auto
      end
      \"\"\"

      {:ok, result} = AtpClient.Isabelle.query(theory, "Example")
      # => {:ok, :thm}

  For fine-grained workflows, open a session once and reuse it:

      {:ok, session} = AtpClient.Isabelle.open_session()
      {:ok, result1} = AtpClient.Isabelle.prove_theory(session, theory1, "T1")
      {:ok, result2} = AtpClient.Isabelle.prove_theory(session, theory2, "T2")
      :ok = AtpClient.Isabelle.close_session(session)
  """

  alias AtpClient.Config
  alias AtpClient.Isabelle.Session
  alias AtpClient.ResultNormalization

  @typedoc """
  The result of a call to `prove_theory/4` or `query/3`:

    * `{:ok, result}` where `result` is either the normalized ATP result or
      the raw Isabelle status list, depending on the `:raw` option;
    * `{:error, {:isabelle_failed, payload, status}}` when the server
      reports a terminal `failed:` message (e.g. a theory file that
      Isabelle could not load);
    * `{:error, {:timeout, status}}` when polling did not observe a
      `:finished` or `:failed` message before the deadline, with `status`
      being the accumulated poll output so far;
    * other `{:error, reason}` for connection and I/O issues.
  """
  @type result ::
          {:ok, ResultNormalization.atp_result()}
          | {:ok, keyword()}
          | {:error, term()}

  @doc """
  Connects to the Isabelle server, starts a session (typically `HOL` or
  `Main`), and returns a `Session` handle. The caller is responsible for
  eventually passing the handle to `close_session/1`.

  ## Options

    * `:host`, `:port`, `:password` — override config;
    * `:session` — name of the Isabelle session to start (default from
      config, typically `"HOL"`);
    * `:session_start_timeout_ms` — how long to wait for the initial
      `session_start` to emit a `:finished` message (default `120_000`).
  """
  @spec open_session(keyword()) :: {:ok, Session.t()} | {:error, term()}
  def open_session(opts \\ []) do
    config = Config.get(:isabelle, opts)

    with {:ok, socket} <- connect(config),
         {:ok, session_id} <- start_session(socket, config) do
      {:ok, %Session{socket: socket, session_id: session_id, config: config}}
    end
  end

  @doc """
  Stops the session and closes the socket. Any errors from the server-side
  `session_stop` are swallowed, since the socket is torn down regardless.
  """
  @spec close_session(Session.t()) :: :ok
  def close_session(%Session{socket: socket, session_id: session_id}) do
    try do
      IsabelleClientMini.stop_session(socket, session_id)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    # Drain any outstanding messages before closing the port so the server
    # doesn't see a half-written command.
    try do
      IsabelleClientMini.poll_status(socket)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    if is_port(socket) and Port.info(socket) != nil do
      Port.close(socket)
    end

    :ok
  end

  @doc """
  Writes `theory_text` to `<local_dir>/<theory_name>.thy`, asks the Isabelle
  server to process it in the given session, and blocks until results are in.

  By default the result is interpreted by
  `AtpClient.ResultNormalization.interpret_isabelle_status/1`. Pass
  `raw: true` to get back the full status keyword list returned by
  `IsabelleClientMini.poll_status/1`.

  ## Options

    * `:raw` — return the raw status list (default `false`);
    * `:use_theories_timeout_ms` — overall deadline for polling (default
      from config, `120_000`);
    * `:poll_interval_ms` — how long to wait between polls (default from
      config, `500`).
  """
  @spec prove_theory(Session.t(), String.t(), String.t(), keyword()) :: result()
  def prove_theory(%Session{} = session, theory_text, theory_name, opts \\ [])
      when is_binary(theory_text) and is_binary(theory_name) do
    config = Keyword.merge(session.config, opts)
    raw? = Keyword.get(opts, :raw, false)

    # Paths are expanded to absolute up-front. `local_dir` is where this
    # BEAM node writes the .thy file; `isabelle_dir` (a.k.a. `master_dir`
    # for the Isabelle server) is the same directory from the server's
    # perspective. When the two are on the same filesystem, a single
    # absolute path works for both; when they differ (e.g. the server
    # runs in a container), the user sets `isabelle_dir` explicitly.
    local_dir = Path.expand(Config.fetch!(:isabelle, :local_dir, config))

    isabelle_dir =
      case Keyword.get(config, :isabelle_dir) do
        nil -> local_dir
        explicit -> explicit
      end

    result =
      with :ok <- File.mkdir_p(local_dir),
           :ok <-
             File.write(Path.join(local_dir, theory_name <> ".thy"), theory_text),
           :ok <- invoke_use_theories(session, theory_name, isabelle_dir),
           {:ok, status} <- wait_for_finished(session.socket, config) do
        if raw?,
          do: {:ok, status},
          else: {:ok, ResultNormalization.interpret_isabelle_status(status)}
      end

    annotate_path_error(result, local_dir, isabelle_dir, theory_name)
  end

  # "Cannot load theory file" almost always means `local_dir` and
  # `isabelle_dir` point at places the BEAM and Isabelle see differently
  # (typical when Isabelle runs in a container). Enrich the error so the
  # user sees both paths side by side.
  defp annotate_path_error(
         {:error, {:isabelle_failed, %{"message" => msg} = payload, _status}} = err,
         local_dir,
         isabelle_dir,
         theory_name
       ) do
    if is_binary(msg) and String.contains?(msg, "Cannot load theory file") do
      {:error,
       {:isabelle_failed, payload,
        [
          hint:
            "Isabelle could not read the theory file. The library wrote " <>
              "#{Path.join(local_dir, theory_name <> ".thy")} on the BEAM side " <>
              "and asked Isabelle to load it from master_dir=#{isabelle_dir}. " <>
              "If Isabelle runs in a different container/host, configure " <>
              ":isabelle_dir to a path that resolves to the same directory " <>
              "on the server.",
          local_dir: local_dir,
          isabelle_dir: isabelle_dir
        ]}}
    else
      err
    end
  end

  defp annotate_path_error(other, _local_dir, _isabelle_dir, _theory_name), do: other

  @doc """
  Convenience wrapper: opens a session, calls `prove_theory/4`, and
  unconditionally closes the session afterwards (even on error).
  """
  @spec query(String.t(), String.t(), keyword()) :: result()
  def query(theory_text, theory_name, opts \\ []) do
    case open_session(opts) do
      {:ok, session} ->
        try do
          prove_theory(session, theory_text, theory_name, opts)
        after
          close_session(session)
        end

      {:error, _} = err ->
        err
    end
  end

  # --- internal -------------------------------------------------------

  defp connect(config) do
    host = Config.fetch!(:isabelle, :host, config)
    port = Config.fetch!(:isabelle, :port, config)
    password = Config.fetch!(:isabelle, :password, config)

    try do
      socket = IsabelleClientMini.connect(password, host, port)
      {:ok, socket}
    rescue
      e -> {:error, {:connect_failed, Exception.message(e)}}
    catch
      kind, reason -> {:error, {:connect_failed, {kind, reason}}}
    end
  end

  defp start_session(socket, config) do
    session_name = Config.fetch(:isabelle, :session, "HOL", config)

    timeout_ms = Config.fetch(:isabelle, :session_start_timeout_ms, 120_000, config)

    poll_ms = Config.fetch(:isabelle, :poll_interval_ms, 500, config)

    try do
      IsabelleClientMini.start_session(socket, %{session: session_name})
    rescue
      e -> {:error, {:session_start_failed, Exception.message(e)}}
    catch
      kind, reason -> {:error, {:session_start_failed, {kind, reason}}}
    else
      _ ->
        case wait_for_finished_raw(socket, poll_ms, deadline(timeout_ms)) do
          {:ok, status} ->
            case Keyword.get(status, :finished) do
              %{"session_id" => session_id} -> {:ok, session_id}
              other -> {:error, {:session_start_failed, other}}
            end

          err ->
            err
        end
    end
  end

  defp invoke_use_theories(
         %Session{socket: socket, session_id: session_id},
         theory_name,
         master_dir
       ) do
    args = %{
      "session_id" => session_id,
      "theories" => [theory_name],
      "master_dir" => ensure_trailing_slash(master_dir)
    }

    try do
      case IsabelleClientMini.use_theories(socket, args) do
        {:ok, _} -> :ok
        :ok -> :ok
        other -> {:error, {:use_theories_failed, other}}
      end
    rescue
      e -> {:error, {:use_theories_failed, Exception.message(e)}}
    catch
      kind, reason -> {:error, {:use_theories_failed, {kind, reason}}}
    end
  end

  defp wait_for_finished(socket, config) do
    timeout_ms = Config.fetch(:isabelle, :use_theories_timeout_ms, 120_000, config)
    poll_ms = Config.fetch(:isabelle, :poll_interval_ms, 500, config)
    wait_for_finished_raw(socket, poll_ms, deadline(timeout_ms))
  end

  defp wait_for_finished_raw(socket, poll_ms, deadline, acc \\ []) do
    Process.sleep(poll_ms)

    new_messages =
      try do
        IsabelleClientMini.poll_status(socket)
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    # `poll_status/1` returns `{:error, "nothing in buffer... wait a bit"}`
    # every time the socket has nothing pending. These are not real errors,
    # just a "not-ready-yet" signal, so we drop them before they flood the
    # accumulator.
    filtered =
      new_messages
      |> List.wrap()
      |> Enum.reject(fn
        {:error, msg} when is_binary(msg) -> String.starts_with?(msg, "nothing in buffer")
        _ -> false
      end)

    combined = acc ++ filtered

    cond do
      Keyword.has_key?(combined, :finished) ->
        {:ok, combined}

      Keyword.has_key?(combined, :failed) ->
        # Terminal failure from Isabelle (e.g. theory file not found,
        # session build failed). Surface it as an infrastructure-level
        # error rather than routing it through result normalization — it
        # isn't a prover verdict on the problem.
        {:error, {:isabelle_failed, Keyword.get(combined, :failed), combined}}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:timeout, combined}}

      true ->
        wait_for_finished_raw(socket, poll_ms, deadline, combined)
    end
  end

  defp deadline(timeout_ms) do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  defp ensure_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end
end
