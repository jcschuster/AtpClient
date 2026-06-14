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

  Pass a full theory or just the body — bare text is automatically wrapped in
  `theory <name> imports Main begin ... end`:

      # Full theory
      theory = ~S\"\"\"
      theory Example imports Main begin
      lemma "P \\<or> \\<not> P" by auto
      end
      \"\"\"

      # Or just the body (equivalent)
      body = ~S\"\"\"
      lemma "P \\<or> \\<not> P" by auto
      \"\"\"

      {:ok, :thm} = AtpClient.Isabelle.query(theory, "Example")
      {:ok, :thm} = AtpClient.Isabelle.query(body, "Example")

  For fine-grained workflows, open a session once and reuse it:

      {:ok, session} = AtpClient.Isabelle.open_session()
      {:ok, result1} = AtpClient.Isabelle.prove_theory(session, theory1, "T1")
      {:ok, result2} = AtpClient.Isabelle.prove_theory(session, theory2, "T2")
      :ok = AtpClient.Isabelle.close_session(session)

  ## Submitting TPTP/THF problems

  `query_tptp/2` and `prove_tptp/3` accept a TPTP/THF problem string and
  route it through `IsabelleClient.TPTP.isabellize_theory/1` before handing
  it to the per-lemma path. The bundled `TPTP.thy` support theory is copied
  into `:local_dir` on first use, and the generated theory imports it with
  `unbundle from_TPTP` active:

      problem = ~S\"\"\"
      thf(p_type, type, p: $i > $o).
      thf(g, conjecture, ! [X: $i]: (p @ X | ~ (p @ X))).
      \"\"\"

      {:ok, lemma_results} = AtpClient.Isabelle.query_tptp(problem)

  Lemma names propagate from TPTP formula names. Lemma line numbers refer
  to the generated theory, not the input TPTP source — match on `:name`
  for UI attribution.
  """

  alias AtpClient.Config
  alias AtpClient.Isabelle.Session
  alias AtpClient.ResultNormalization
  alias IsabelleClient.Shared
  alias IsabelleClient.Task
  alias IsabelleClient.Theory
  alias IsabelleClient.TPTP

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
  and returns a `Session` handle backed by an `IsabelleClient.Shared` GenServer.
  The caller is responsible for eventually passing the handle to `close_session/1`.

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

    case Shared.start_link(
           password: password,
           host: host,
           port: port,
           session: session_name,
           connect_timeout: 30_000,
           timeout: timeout_ms
         ) do
      {:ok, pid} ->
        {:ok, %Session{client: pid, config: config}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops the active Isabelle session and shuts down the underlying
  `IsabelleClient.Shared` GenServer, closing its TCP socket.
  """
  @spec close_session(Session.t()) :: :ok
  def close_session(%Session{client: pid}) do
    Shared.close(pid)
  end

  @doc """
  Writes `theory_text` to `<local_dir>/<theory_name>.thy`, asks the Isabelle
  server to process it in the given session, and blocks until the task finishes
  or fails.

  If `theory_text` does not begin with `theory`, it is automatically wrapped:

      theory <theory_name> imports <imports> begin
      <theory_text>
      end

  By default the result is interpreted by
  `AtpClient.ResultNormalization.interpret_isabelle_result/1`. Pass `raw: true`
  to get back the full `use_theories` payload (a map with `"nodes"`, `"ok"`,
  `"errors"`, …) returned by the Isabelle server.

  ## Options

    * `:raw` — return the raw payload map (default `false`);
    * `:imports` — session/theory to import when auto-wrapping (default `"Main"`);
    * `:use_theories_timeout_ms` — overall deadline for the task (default from
      config, `120_000`).
  """
  @spec prove_theory(Session.t(), String.t(), String.t(), keyword()) :: result()
  def prove_theory(%Session{} = session, theory_text, theory_name, opts \\ [])
      when is_binary(theory_text) and is_binary(theory_name) do
    config = Keyword.merge(session.config, opts)
    raw? = Keyword.get(opts, :raw, false)
    imports = Keyword.get(opts, :imports, "Main")

    local_dir = Path.expand(Config.fetch!(:isabelle, :local_dir, config))

    isabelle_dir =
      case Keyword.get(config, :isabelle_dir) do
        nil -> local_dir
        explicit -> explicit
      end

    timeout_ms = Config.fetch(:isabelle, :use_theories_timeout_ms, 120_000, config)
    theory_source = Theory.source(theory_name, theory_text, imports)

    result =
      with :ok <- File.mkdir_p(local_dir),
           :ok <- File.write(Path.join(local_dir, theory_name <> ".thy"), theory_source),
           {:ok, %Task{result: payload}} <-
             Shared.use_theories(
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
  Like `prove_theory/4`, but returns one result per lemma instead of a single
  consolidated result.

  Calls `prove_theory/4` internally with `raw: true` and parses the payload via
  `AtpClient.ResultNormalization.per_lemma_results/2`. Returns
  `{:ok, [lemma_result]}` for a finished task, where each entry is:

      %{
        line:   non_neg_integer() | nil,  # line in the caller's text (1-based)
        name:   String.t() | nil,          # lemma name, or nil for anonymous
        result: {:ok, :thm} | {:ok, :gave_up}
      }

  The list is sorted by line number. When auto-wrapping is applied (the text
  does not begin with `theory`), Isabelle's reported line numbers are adjusted
  so that the first line of the body is line 1.

  Returns `{:error, term()}` for connection failures and for tasks that fail
  before producing any messages (e.g. unreadable theory files).

  ## Options

  Same as `prove_theory/4` except `:raw`, which is always overridden.
  """
  @spec prove_lemmas(Session.t(), String.t(), String.t(), keyword()) ::
          {:ok, [ResultNormalization.lemma_result()]} | {:error, term()}
  def prove_lemmas(%Session{} = session, theory_text, theory_name, opts \\ [])
      when is_binary(theory_text) and is_binary(theory_name) do
    line_offset = if needs_wrap?(theory_text), do: 1, else: 0

    case prove_theory(session, theory_text, theory_name, Keyword.put(opts, :raw, true)) do
      {:ok, payload} ->
        {:ok, ResultNormalization.per_lemma_results(payload, line_offset: line_offset)}

      {:error, {:isabelle_failed, _, _}} = err ->
        err

      {:error, _} = err ->
        err
    end
  end

  defp needs_wrap?(text), do: not Regex.match?(~r/\A\s*theory\s+/u, text)

  @doc """
  Convenience wrapper: opens a session, calls `prove_lemmas/4`, and
  unconditionally closes the session afterwards (even on error).
  """
  @spec query_lemmas(String.t(), String.t(), keyword()) ::
          {:ok, [ResultNormalization.lemma_result()]} | {:error, term()}
  def query_lemmas(theory_text, theory_name, opts \\ []) do
    case open_session(opts) do
      {:ok, session} ->
        try do
          prove_lemmas(session, theory_text, theory_name, opts)
        after
          close_session(session)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Like `prove_lemmas/4`, but takes a TPTP/THF problem string instead of an
  Isabelle theory.

  The problem is converted to an Isabelle theory body via
  `IsabelleClient.TPTP.isabellize_theory/1`, which maps `thf(name, axiom, …)`
  to `axiomatization`, `thf(name, type, …)` to `consts`/`typedecl`/
  `type_synonym`, and `thf(name, theorem|conjecture, …)` to `lemma`. The
  generated body is preceded by `unbundle from_TPTP` so that the TPTP/THF
  notation parses inside Isabelle, then handed to `prove_lemmas/4` with
  `imports: "TPTP"`.

  The bundled `TPTP.thy` support theory is copied into the configured
  `:local_dir` on first use so Isabelle's loader can resolve
  `imports "TPTP"` from the generated theory file. Existing files are not
  overwritten.

  ## Lemma line numbers

  Lemma line numbers in the returned `lemma_result()` entries refer to the
  *generated* theory, not the input TPTP source. Match on `:name`
  (carried over from the TPTP formula name) rather than `:line` for UI
  attribution.

  ## Options

  Same as `prove_lemmas/4`, plus:

    * `:theory_name` — name to use for the generated Isabelle theory
      (default: a content-derived `AtpClient_<hash>` string). Useful for
      stable filenames across runs.
    * `:proof_method` — Isabelle tactic appended to each generated `lemma`
      (default `"by auto"`). The isabellizer emits `lemma` declarations
      without proofs, which Isabelle treats as unfinished goals; a tactic
      must be supplied for the goal to close (or be withdrawn). Pass
      `"by metis"` for first-order portfolio reasoning, or
      `"sledgehammer nitpick oops"` to probe both proof and
      countersatisfiability; the latter relies on the per-lemma classifier
      recognising sledgehammer's `"found a proof"` and nitpick's verdicts
      directly, so `oops` is fine — `{:ok, :thm}` / `{:ok, :csat}` /
      `{:ok, :sat}` come from the tool messages, not from a `theorem name:`
      completion.

  ## Errors

    * `{:error, {:tptp_thy_copy_failed, reason}}` — could not place
      `TPTP.thy` next to the generated theory in `:local_dir`;
    * `{:error, {:tptp_parse, message}}` — `isabellize_theory/1` raised
      (the parser is tolerant by design, so this should be rare);
    * everything `prove_lemmas/4` can return.
  """
  @spec prove_tptp(Session.t(), String.t(), keyword()) ::
          {:ok, [ResultNormalization.lemma_result()]} | {:error, term()}
  def prove_tptp(%Session{} = session, problem, opts \\ []) when is_binary(problem) do
    config = Keyword.merge(session.config, opts)
    local_dir = Path.expand(Config.fetch!(:isabelle, :local_dir, config))
    proof_method = Keyword.get(opts, :proof_method, "by auto")

    with :ok <- File.mkdir_p(local_dir),
         :ok <- ensure_tptp_theory(local_dir),
         {:ok, isabellized} <- safe_isabellize(problem) do
      name = Keyword.get(opts, :theory_name) || derive_name(problem)
      body = "unbundle from_TPTP\n\n" <> inject_proof_method(isabellized, proof_method)

      prove_lemmas(session, body, name, Keyword.put(opts, :imports, ~s("TPTP")))
    end
  end

  @doc """
  Convenience wrapper: opens a session, calls `prove_tptp/3`, and
  unconditionally closes the session afterwards (even on error).
  """
  @spec query_tptp(String.t(), keyword()) ::
          {:ok, [ResultNormalization.lemma_result()]} | {:error, term()}
  def query_tptp(problem, opts \\ []) when is_binary(problem) do
    case open_session(opts) do
      {:ok, session} ->
        try do
          prove_tptp(session, problem, opts)
        after
          close_session(session)
        end

      {:error, _} = err ->
        err
    end
  end

  defp inject_proof_method(isabellized, proof_method) do
    isabellized
    |> String.split(~r/\n\n+/)
    |> Enum.map(fn item ->
      if String.starts_with?(String.trim_leading(item), "lemma ") do
        String.trim_trailing(item) <> "\n  " <> proof_method
      else
        item
      end
    end)
    |> Enum.join("\n\n")
  end

  defp ensure_tptp_theory(local_dir) do
    dest = Path.join(local_dir, "TPTP.thy")

    if File.exists?(dest) do
      :ok
    else
      case File.cp(TPTP.source_path(), dest) do
        :ok -> :ok
        {:error, reason} -> {:error, {:tptp_thy_copy_failed, reason}}
      end
    end
  end

  defp safe_isabellize(problem) do
    {:ok, TPTP.isabellize_theory(problem)}
  rescue
    e -> {:error, {:tptp_parse, Exception.message(e)}}
  end

  defp derive_name(problem) do
    hash =
      :crypto.hash(:sha256, problem)
      |> Base.encode16(case: :lower)

    "AtpClient_" <> binary_part(hash, 0, 12)
  end

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
