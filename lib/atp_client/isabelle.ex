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
        session: "HOL"

  When the BEAM and the Isabelle server run on the same host (the usual dev
  setup) no further configuration is required — `:local_dir` defaults to a
  subdirectory of `System.tmp_dir!/0` and the library writes `.thy` files
  there before asking Isabelle to load them. Pass theory text in, get
  results back; the file bookkeeping is hidden.

  ### Paths: `local_dir` vs. `isabelle_dir`

  Only relevant when the BEAM node and the Isabelle server see the shared
  directory under different paths. In that case set both explicitly:

      config :atp_client, :isabelle,
        local_dir: "/shared/problems",
        isabelle_dir: "/data/problems"

  The two common cases:

    * **Containers:** BEAM writes to `/shared/problems` inside its container;
      the Isabelle server container has the same volume mounted at
      `/data/problems`.
    * **Windows + Cygwin:** BEAM on Windows sees `C:/Users/you/thy`; Isabelle
      started from a Cygwin shell sees the same directory as
      `/cygdrive/c/Users/you/thy`.

  Paths given via `isabelle_dir` are passed through verbatim — the library does
  not try to translate Windows paths to POSIX or vice-versa. When unset,
  `:isabelle_dir` defaults to `:local_dir`.

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

      {:ok, :thm} = AtpClient.Isabelle.query(theory, "Example", [])
      {:ok, :thm} = AtpClient.Isabelle.query(body, "Example", [])

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

  Lemma names propagate from TPTP formula names. Line numbers are not
  exposed — they would refer to the generated theory, not the input TPTP
  source. Match on `:name` for UI attribution.

  ## Cancellation

  Death of the process calling `query/2`, `query_tptp/2`, or any of the
  session helpers is the abort signal. The session is owned by an internal
  GenServer that monitors the caller; on caller `:DOWN` it stops the
  underlying `IsabelleClient.Shared`, which closes the TCP socket to the
  Isabelle server. Closing the socket while a
  `use_theories` task is in flight aborts that task on the server side —
  per the Isabelle protocol, the running check is dropped along with the
  session.

  `IsabelleClient` does not currently expose a way to cancel a single
  in-flight task while keeping the session open, so cancelled calls pay
  the session-start cost again on the next request (typically a few
  seconds for `HOL`, longer for larger sessions). Callers that need to
  cancel cheaply should keep the volume of cancelled work small or open
  multiple sessions in parallel.
  """

  @behaviour AtpClient.Backend

  alias AtpClient.Config
  alias AtpClient.Config.Field
  alias AtpClient.Isabelle.Session
  alias AtpClient.Isabelle.SessionOwner
  alias AtpClient.ResultNormalization
  alias IsabelleClient.Shared
  alias IsabelleClient.Task
  alias IsabelleClient.Theory
  alias IsabelleClient.TPTP

  @impl AtpClient.Backend
  def config_key, do: :isabelle

  @impl AtpClient.Backend
  def label, do: "Isabelle"

  @impl AtpClient.Backend
  def config_schema do
    [
      %Field{
        key: :host,
        type: :string,
        required?: false,
        group: :connection,
        default: "127.0.0.1",
        label: "Server host"
      },
      %Field{
        key: :port,
        type: :integer,
        required?: false,
        group: :connection,
        default: 9999,
        label: "Server port"
      },
      %Field{
        key: :password,
        type: :string,
        required?: true,
        group: :connection,
        secret?: true,
        label: "Server password"
      },
      %Field{
        key: :local_dir,
        type: :string,
        required?: false,
        group: :connection,
        label: "Shared theory directory",
        doc:
          "Where AtpClient writes .thy files (BEAM-side view). " <>
            "Defaults to a subdirectory of System.tmp_dir!/0; only set this " <>
            "when the BEAM and the Isabelle server see the directory under " <>
            "different paths (containers, Cygwin)."
      },
      %Field{
        key: :isabelle_dir,
        type: :string,
        required?: false,
        group: :connection,
        label: "Server-side theory directory",
        doc:
          "Same directory as seen by the Isabelle server. " <>
            "Defaults to the local path when blank."
      },
      %Field{
        key: :session,
        type: :string,
        required?: false,
        group: :defaults,
        default: "HOL",
        label: "Default session"
      }
    ]
  end

  @impl AtpClient.Backend
  def verify(opts \\ []) do
    case open_session(opts) do
      {:ok, session} -> close_session(session)
      {:error, _} = err -> err
    end
  end

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
  and returns a `Session` handle.

  The handle is backed by a private owner process that holds the link to
  `IsabelleClient.Shared` for you, so callers do **not** need to trap exits: a failed connection surfaces as `{:error, reason}` and a
  later crash of the Shared process surfaces as a `:DOWN` if the caller
  monitors `session.client`. The owner is also caller-monitored, so if the
  caller dies the session is shut down cleanly instead of orphaning a remote
  Isabelle session.

  The caller is still responsible for eventually passing the handle to
  `close_session/1` under normal control flow.

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

    shared_opts = [
      password: password,
      host: host,
      port: port,
      session: session_name,
      connect_timeout: 30_000,
      timeout: timeout_ms
    ]

    case SessionOwner.start(shared_opts) do
      {:ok, owner} ->
        {:ok,
         %Session{
           client: SessionOwner.shared_pid(owner),
           owner: owner,
           config: config
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops the active Isabelle session and shuts down the underlying
  `IsabelleClient.Shared` GenServer, closing its TCP socket.
  """
  @spec close_session(Session.t()) :: :ok
  def close_session(%Session{owner: owner}) do
    if Process.alive?(owner), do: GenServer.stop(owner, :normal)
    :ok
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
  Extracts the lemma specs (name + body-line range) from a theory body.

  Walks the body line-by-line, picking out `lemma <name>:` or
  `lemma <name>[…]:` declarations and computing each lemma's range as
  `[its line .. (line before the next lemma)]`. Used by `prove_lemmas/4`
  and `prove_tptp/3` to feed `ResultNormalization.per_lemma_results/3`
  without having to re-parse the body inside the classifier.
  """
  @spec lemma_specs(String.t()) :: [ResultNormalization.lemma_spec()]
  def lemma_specs(theory_text) when is_binary(theory_text) do
    lines = String.split(theory_text, "\n")
    total = length(lines)

    starts =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_no} ->
        case Regex.run(~r/^lemma\s+([A-Za-z_][A-Za-z0-9_'.]*)/, line) do
          [_, name] -> [{name, line_no}]
          _ -> []
        end
      end)

    starts
    |> Enum.with_index()
    |> Enum.map(fn {{name, start}, idx} ->
      stop =
        case Enum.at(starts, idx + 1) do
          {_, next_start} -> next_start - 1
          nil -> total
        end

      %{name: name, range: start..stop}
    end)
  end

  @doc """
  Like `prove_theory/4`, but returns one result per lemma instead of a single
  consolidated result.

  Calls `prove_theory/4` internally with `raw: true` and parses the payload via
  `AtpClient.ResultNormalization.per_lemma_results/3`. Returns
  `{:ok, [lemma_result]}` for a finished task, where entries follow the order
  of the `lemma <name>:` declarations in the input body:

      %{
        name:   String.t(),                # lemma name from the body
        result: {:ok, :thm} | {:ok, :csat} | {:ok, :sat}
              | {:ok, :gave_up} | {:ok, :timeout} | {:ok, :out_of_resources}
      }

  Unnamed `lemma "…" by …` declarations are not represented in the result —
  the classifier buckets messages by lemma name extracted from the body.

  Returns `{:error, term()}` for connection failures and for tasks that fail
  before producing any messages (e.g. unreadable theory files).

  ## Options

  Same as `prove_theory/4` except `:raw`, which is always overridden.
  """
  @spec prove_lemmas(Session.t(), String.t(), String.t(), keyword()) ::
          {:ok, [ResultNormalization.lemma_result()]} | {:error, term()}
  def prove_lemmas(%Session{} = session, theory_text, theory_name, opts \\ [])
      when is_binary(theory_text) and is_binary(theory_name) do
    specs = lemma_specs(theory_text)
    # Auto-wrapping prepends `theory <name> imports <…> begin\n`, which
    # shifts every line of the body down by one in the on-disk file.
    line_offset = if needs_wrap?(theory_text), do: 1, else: 0

    case prove_theory(session, theory_text, theory_name, Keyword.put(opts, :raw, true)) do
      {:ok, payload} ->
        {:ok,
         ResultNormalization.per_lemma_results(
           payload,
           specs,
           file: "/" <> theory_name <> ".thy",
           line_offset: line_offset
         )}

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

  ## Result attribution

  Entries in the returned `lemma_result()` list follow the order of the
  `thf(…, conjecture, …)` declarations in the input problem and carry the
  TPTP formula name as `:name`. Line numbers are intentionally not
  exposed: they would refer to the generated theory body rather than the
  caller's TPTP source.

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

  @impl AtpClient.Backend
  @doc """
  Behaviour entry point: proves `problem` (a TPTP-format string) and
  collapses the per-lemma results from `query_tptp/2` into a single
  `t:AtpClient.ResultNormalization.atp_result/0`.

  Aggregation is weakest-link: any non-`{:ok, :thm}` entry wins, so the
  unified result only reads `{:ok, :thm}` when every isabellized lemma was
  discharged. Callers that need per-lemma detail should use `query_tptp/2`
  directly.
  """
  @spec query(String.t(), keyword()) ::
          ResultNormalization.atp_result() | {:error, term()}
  def query(problem, opts \\ []) when is_binary(problem) do
    case query_tptp(problem, opts) do
      {:ok, lemmas} -> aggregate_lemma_results(lemmas)
      {:error, _} = err -> err
    end
  end

  defp aggregate_lemma_results([]), do: {:ok, :gave_up}

  defp aggregate_lemma_results(lemmas) do
    Enum.find_value(lemmas, {:ok, :thm}, fn %{result: r} ->
      if r != {:ok, :thm}, do: r
    end)
  end

  defp inject_proof_method(isabellized, proof_method) do
    isabellized
    |> String.split(~r/\n\n+/)
    |> Enum.map_join("\n\n", fn item ->
      if String.starts_with?(String.trim_leading(item), "lemma ") do
        String.trim_trailing(item) <> "\n  " <> proof_method
      else
        item
      end
    end)
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

  `opts` must be passed explicitly (use `[]` for none) — a default value
  would shadow `query/2` from `AtpClient.Backend`.
  """
  @spec query(String.t(), String.t(), keyword()) :: result()
  def query(theory_text, theory_name, opts) do
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
