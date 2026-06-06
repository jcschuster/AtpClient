defmodule AtpClient.Isabelle do
  @moduledoc """
  Client for Isabelle servers, built on top of `IsabelleClient` from the
  `:isabelle_elixir` package.

  The Isabelle server cannot accept theory text over the wire — theories have
  to live as `.thy` files on a filesystem that both the BEAM node running
  AtpClient and the Isabelle server can see. This module handles the file
  bookkeeping for you: you pass the theory body as a string, and it is written
  into a configured shared directory before `use_theories` is invoked.

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
    * **Windows + Cygwin:** BEAM on Windows sees `C:/Users/you/thy`; Isabelle
      started from a Cygwin shell sees the same directory as
      `/cygdrive/c/Users/you/thy`. Set both accordingly.

  Paths given via `isabelle_dir` are passed through verbatim — the library does
  not try to translate Windows paths to POSIX or vice-versa.

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
  alias IsabelleClient.Task

  @typedoc """
  The result of a call to `prove_theory/4` or `query/3`:

    * `{:ok, result}` where `result` is either the normalized ATP result or the
      raw `use_theories` payload (a map with `"nodes"`, `"errors"`, `"ok"`, …),
      depending on the `:raw` option;
    * `{:error, {:isabelle_failed, payload, notes}}` when the server reports a
      `FAILED` message for the task (e.g. a theory file that Isabelle could not
      load). `notes` is the list of intermediate `NOTE` payloads accumulated by
      `IsabelleClient.Task` before the failure;
    * `{:error, {:isabelle_failed, payload, hints}}` — same shape, but with
      `hints` carrying diagnostic suggestions and the `local_dir` /
      `isabelle_dir` actually used. Currently emitted when the server reports
      "Cannot load theory file";
    * other `{:error, reason}` for connection, session-start, and I/O issues.
  """
  @type result ::
          {:ok, ResultNormalization.atp_result()}
          | {:ok, map()}
          | {:error, term()}

  @doc """
  Connects to the Isabelle server, starts a session (typically `HOL` or `Main`),
  and returns a `Session` handle. The caller is responsible for eventually
  passing the handle to `close_session/1`.

  ## Options

    * `:host`, `:port`, `:password` — override config;
    * `:session` — name of the Isabelle session to start (default from config,
      typically `"HOL"`);
    * `:session_start_timeout_ms` — how long to wait for the initial
      `session_start` to complete (default `120_000`).
  """
  @spec open_session(keyword()) :: {:ok, Session.t()} | {:error, term()}
  def open_session(opts \\ []) do
    config = Config.get(:isabelle, opts)

    host = Config.fetch!(:isabelle, :host, config)
    port = Config.fetch!(:isabelle, :port, config)
    password = Config.fetch!(:isabelle, :password, config)
    session_name = Config.fetch(:isabelle, :session, "HOL", config)
    timeout_ms = Config.fetch(:isabelle, :session_start_timeout_ms, 120_000, config)

    case IsabelleClient.connect(password, host: host, port: port) do
      {:ok, client} ->
        start_session_or_close(client, session_name, timeout_ms, config)

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp start_session_or_close(client, session_name, timeout_ms, config) do
    case IsabelleClient.start_session(client, %{"session" => session_name}, timeout_ms) do
      {:ok, started_client, _task} ->
        {:ok, %Session{client: started_client, config: config}}

      {:error, %Task{} = task} ->
        _ = safe_close(client)
        {:error, {:session_start_failed, task}}

      {:error, reason} ->
        _ = safe_close(client)
        {:error, {:session_start_failed, reason}}

      other ->
        _ = safe_close(client)
        {:error, {:session_start_failed, other}}
    end
  end

  @doc """
  Stops the session and closes the socket. Errors from the server-side
  `session_stop` are swallowed, since the socket is torn down regardless.
  """
  @spec close_session(Session.t()) :: :ok
  def close_session(%Session{client: client}) do
    _ = safe_stop_session(client)
    _ = safe_close(client)
    :ok
  end

  defp safe_stop_session(%IsabelleClient{sessions: []}), do: :ok

  defp safe_stop_session(%IsabelleClient{} = client) do
    try do
      IsabelleClient.stop_session(client)
      :ok
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp safe_close(%IsabelleClient{} = client) do
    try do
      IsabelleClient.close(client)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  @doc """
  Writes `theory_text` to `<local_dir>/<theory_name>.thy`, asks the Isabelle
  server to process it in the given session, and blocks until the task finishes
  or fails.

  By default the result is interpreted by
  `AtpClient.ResultNormalization.interpret_isabelle_result/1`. Pass `raw: true`
  to get back the full `use_theories` payload (a map with `"nodes"`, `"ok"`,
  `"errors"`, …) returned by the Isabelle server.

  ## Options

    * `:raw` — return the raw payload map (default `false`);
    * `:use_theories_timeout_ms` — overall deadline for the task (default from
      config, `120_000`).
  """
  @spec prove_theory(Session.t(), String.t(), String.t(), keyword()) :: result()
  def prove_theory(%Session{} = session, theory_text, theory_name, opts \\ [])
      when is_binary(theory_text) and is_binary(theory_name) do
    config = Keyword.merge(session.config, opts)
    raw? = Keyword.get(opts, :raw, false)

    local_dir = Path.expand(Config.fetch!(:isabelle, :local_dir, config))

    isabelle_dir =
      case Keyword.get(config, :isabelle_dir) do
        nil -> local_dir
        explicit -> explicit
      end

    timeout_ms = Config.fetch(:isabelle, :use_theories_timeout_ms, 120_000, config)

    result =
      with :ok <- File.mkdir_p(local_dir),
           :ok <- File.write(Path.join(local_dir, theory_name <> ".thy"), theory_text),
           {:ok, %Task{result: payload}} <-
             IsabelleClient.use_theories(
               session.client,
               %{"theories" => [theory_name], "master_dir" => isabelle_dir},
               timeout_ms
             ) do
        if raw?,
          do: {:ok, payload},
          else: {:ok, ResultNormalization.interpret_isabelle_result(payload)}
      else
        {:error, %Task{status: :failed, result: payload, notes: notes}} ->
          {:error, {:isabelle_failed, payload, notes}}

        {:error, _} = err ->
          err
      end

    annotate_path_error(result, local_dir, isabelle_dir, theory_name)
  end

  defp annotate_path_error(
         {:error, {:isabelle_failed, %{"message" => msg} = payload, _notes}} = err,
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
end
