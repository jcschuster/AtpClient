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

  ### Zero-config: `isabelle` on `$PATH`

  If the `isabelle` executable is discoverable (either on `$PATH` or via the
  `ISABELLE_TOOL` environment variable), the bundled `:isabelle_elixir`
  package can spin up a local resident server on demand. This removes any
  need to configure host/port/password by hand:

      # Start a throwaway server (uses `isabelle` from $PATH).
      {:ok, server} = IsabelleClient.start_server()

      opts = [host: server.host, port: server.port, password: server.password]

      {:ok, session} = AtpClient.Isabelle.open_session(opts)
      {:ok, %AtpClient.Result{status: :theorem}} =
        AtpClient.Isabelle.prove_theory(session, ~S\"\"\"
        lemma "P \\<or> \\<not> P" by auto
        \"\"\", "Example")
      :ok = AtpClient.Isabelle.close_session(session)

      # When you're done, stop the server:
      IsabelleClient.Server.kill(server.name)

  A minimal `config/config.exs` reduces the per-call `opts` to nothing —
  after the one-time `start_server/0` call, put the returned coordinates
  into the application env once and forget about them.

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

  ## Results

  Every proving call returns `{:ok, %AtpClient.Result{}}` or `{:error, reason}`.
  Isabelle prints no SZS lines; the status is read from the server's messages by
  `AtpClient.Isabelle.Verdict`, and the result's `evidence` is
  `{:backend, AtpClient.Isabelle}`. `output` is the text of those messages, and
  `details` carries what the call knows beyond the status:

    * `prove_theory/4` — `%{payload: map()}`, the `use_theories` payload as the
      server returned it.
    * `prove_lemmas/4`, `query_lemmas/3`, `prove_tptp/3` and `query/2` —
      `%{lemmas: [lemma_result], payload: map()}`, one entry per lemma in the
      order of the `lemma` declarations, each `%{name: name, status: status}`.
      The result's own `status` is the weakest link: `:theorem` only when every
      lemma was discharged, otherwise the first other status in lemma order. A
      body with no lemmas is `:gave_up`.

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

      {:ok, session} = AtpClient.Isabelle.open_session()
      {:ok, %{status: :theorem}} = AtpClient.Isabelle.prove_theory(session, theory, "Example")
      {:ok, %{status: :theorem}} = AtpClient.Isabelle.prove_theory(session, body, "Example")
      :ok = AtpClient.Isabelle.close_session(session)

  ## Submitting TPTP/THF problems

  `query/2` and `prove_tptp/3` take an `AtpClient.Problem` and route it through
  `IsabelleClient.TPTP.isabellize_theory/1` before handing it to the per-lemma
  path. The bundled `TPTP.thy` support theory is copied into `:local_dir` on
  first use, and the generated theory imports it with `unbundle from_TPTP`
  active:

      problem = ~S\"\"\"
      thf(p_type, type, p: $i > $o).
      thf(g, conjecture, ! [X: $i]: (p @ X | ~ (p @ X))).
      \"\"\"

      {:ok, result} = AtpClient.Isabelle.query(problem)
      result.status           # :theorem
      result.details.lemmas   # [%{name: "g", status: :theorem}]

  Lemma names propagate from TPTP formula names. Line numbers are not
  exposed — they would refer to the generated theory, not the input TPTP
  source. Match on `:name` for UI attribution.

  ## Cancellation

  Death of the process calling `query/2` or any of the session helpers is the
  abort signal. The session is owned by an internal GenServer that monitors the
  caller; on caller `:DOWN` it stops the underlying `IsabelleClient.Shared`,
  which closes the TCP socket to the Isabelle server. Closing the socket while
  a `use_theories` task is in flight aborts that task on the server side — per
  the Isabelle protocol, the running check is dropped along with the session.

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
  alias AtpClient.Isabelle.Verdict
  alias AtpClient.Problem
  alias AtpClient.Result
  alias IsabelleClient.Shared
  alias IsabelleClient.Task
  alias IsabelleClient.Theory
  alias IsabelleClient.TPTP

  # One shared schema, applied at every public entry point in this module.
  # The composition here is deep (`query/2` -> `open_session/1` +
  # `prove_tptp/3` -> `prove_lemmas/4` -> `run_theory/4`) and each layer
  # forwards `opts` wholesale, so a per-function schema would need to strip
  # keys at each hop. A shared schema catches typos with far less ceremony;
  # the tradeoff is that `close_session/1` won't complain if you pass it
  # `:proof_method` — a harmless overshoot given the alternative.
  @opts_schema NimbleOptions.new!(
                 # Schema-declared connection / defaults (see `config_schema/0`).
                 host: [type: :string],
                 port: [type: :pos_integer],
                 password: [type: :string],
                 session: [type: :string],
                 local_dir: [type: :string],
                 isabelle_dir: [type: :string],

                 # Advanced timeouts — never rendered by a UI, read only via
                 # `Config.fetch/4` in this module.
                 session_start_timeout_ms: [type: :non_neg_integer],
                 use_theories_timeout_ms: [type: :non_neg_integer],

                 # Per-call ephemera.
                 imports: [type: :string, doc: "Isabelle imports clause. Default `\"Main\"`."],
                 proof_method: [
                   type: :string,
                   doc:
                     "Isabelle tactic appended to each generated `lemma` " <>
                       "(TPTP path only). Default `\"by auto\"`."
                 ],
                 theory_name: [
                   type: :string,
                   doc: "Name of the generated theory file (TPTP path only)."
                 ]
               )

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
    NimbleOptions.validate!(opts, @opts_schema)

    case open_session(opts) do
      {:ok, session} -> close_session(session)
      {:error, _} = err -> err
    end
  end

  @typedoc """
  What a proving call returns.

    * `{:ok, %AtpClient.Result{}}` — the task finished; see "Results" in the
      module documentation for what the result carries.
    * `{:error, {:isabelle_failed, payload, notes}}` — the server reported a
      `FAILED` message for the task, such as a theory file it could not load.
      `notes` is the list of intermediate `NOTE` payloads `IsabelleClient.Task`
      accumulated before the failure. When the message is "Cannot load theory
      file", `notes` is replaced by hints carrying the `local_dir` and
      `isabelle_dir` actually used.
    * other `{:error, reason}` for connection, session-start, and I/O issues.
  """
  @type result :: {:ok, Result.t()} | {:error, term()}

  @doc """
  Connects to the Isabelle server, starts a session (typically `HOL` or `Main`),
  and returns a `Session` handle.

  The handle is backed by a private owner process that holds the link to
  `IsabelleClient.Shared` for you, so callers do **not** need to trap
  exits: a failed connection surfaces as `{:error, reason}` and a later
  crash of the Shared process surfaces as a `:DOWN` if the caller
  monitors `AtpClient.Isabelle.Session.client/1`. The owner is also
  caller-monitored, so if the caller dies the session is shut down
  cleanly instead of orphaning a remote Isabelle session.

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
    NimbleOptions.validate!(opts, @opts_schema)
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
        {:ok, Session.new(SessionOwner.shared_pid(owner), owner, config)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops the active Isabelle session and shuts down the underlying
  `IsabelleClient.Shared` GenServer, closing its TCP socket.
  """
  @spec close_session(Session.t()) :: :ok
  def close_session(session) do
    owner = Session.owner(session)
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

  The status is read over every message of the task by
  `AtpClient.Isabelle.Verdict.classify/1`; the `use_theories` payload is in
  `result.details.payload`.

  ## Options

    * `:imports` — session/theory to import when auto-wrapping (default `"Main"`);
    * `:use_theories_timeout_ms` — overall deadline for the task (default from
      config, `120_000`).

  ## Examples

      {:ok, %AtpClient.Result{status: :theorem, details: %{payload: %{"ok" => true}}}} =
        AtpClient.Isabelle.prove_theory(session, "lemma p: True by auto\\n", "P")
  """
  @spec prove_theory(Session.t(), String.t(), String.t(), keyword()) :: result()
  def prove_theory(session, theory_text, theory_name, opts \\ [])
      when is_binary(theory_text) and is_binary(theory_name) do
    NimbleOptions.validate!(opts, @opts_schema)

    with {:ok, payload} <- run_theory(session, theory_text, theory_name, opts) do
      {:ok, result(Verdict.classify(payload), payload, %{payload: payload})}
    end
  end

  # Writes the theory and runs it, returning the `use_theories` payload.
  @spec run_theory(Session.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp run_theory(session, theory_text, theory_name, opts) do
    config = Keyword.merge(Session.config(session), opts)
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
               Session.client(session),
               %{"theories" => [theory_name], "master_dir" => isabelle_dir},
               timeout_ms
             ) do
        {:ok, payload}
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

  @doc false
  # Internal: extracts lemma specs (name + body-line range) from a theory body.
  # Walks the body line-by-line, picking out `lemma <name>:` declarations and
  # computing each lemma's range as `[its line .. (line before the next lemma)]`.
  # Used by `prove_lemmas/4` to feed `Verdict.per_lemma/3` without re-parsing
  # inside the classifier. Retained as public-visibility for tests, not part of
  # the API contract.
  @spec lemma_specs(String.t()) :: [Verdict.lemma_spec()]
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
  Like `prove_theory/4`, but reads one status per lemma.

  The result's `details.lemmas` holds one entry per `lemma <name>:` declaration
  in the body, in that order, each `%{name: name, status: status}`; the result's
  own `status` is the weakest link over them. Unnamed `lemma "…" by …`
  declarations are not represented — the classifier buckets messages by the
  lemma names it finds in the body.

  ## Options

  Same as `prove_theory/4`.
  """
  @spec prove_lemmas(Session.t(), String.t(), String.t(), keyword()) :: result()
  def prove_lemmas(session, theory_text, theory_name, opts \\ [])
      when is_binary(theory_text) and is_binary(theory_name) do
    NimbleOptions.validate!(opts, @opts_schema)
    specs = lemma_specs(theory_text)
    # Auto-wrapping prepends `theory <name> imports <…> begin\n`, which
    # shifts every line of the body down by one in the on-disk file.
    line_offset = if needs_wrap?(theory_text), do: 1, else: 0

    with {:ok, payload} <- run_theory(session, theory_text, theory_name, opts) do
      lemmas =
        Verdict.per_lemma(payload, specs,
          file: "/" <> theory_name <> ".thy",
          line_offset: line_offset
        )

      {:ok, result(weakest(lemmas), payload, %{lemmas: lemmas, payload: payload})}
    end
  end

  defp needs_wrap?(text), do: not Regex.match?(~r/\A\s*theory\s+/u, text)

  @doc """
  Convenience wrapper: opens a session, calls `prove_lemmas/4`, and
  unconditionally closes the session afterwards (even on error).
  """
  @spec query_lemmas(String.t(), String.t(), keyword()) :: result()
  def query_lemmas(theory_text, theory_name, opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)
    with_session(opts, &prove_lemmas(&1, theory_text, theory_name, opts))
  end

  @doc """
  Like `prove_lemmas/4`, but takes an `AtpClient.Problem` in TPTP/THF instead
  of an Isabelle theory.

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

  `result.details.lemmas` follows the order of the `thf(…, conjecture, …)`
  declarations in the input problem and carries the TPTP formula name as
  `:name`. Line numbers are intentionally not exposed: they would refer to
  the generated theory body rather than the caller's TPTP source.

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
      directly, so `oops` is fine — `:theorem` / `:counter_satisfiable` /
      `:satisfiable` come from the tool messages, not from a `theorem name:`
      completion.

  ## Errors

    * `{:error, {:tptp_thy_copy_failed, reason}}` — could not place
      `TPTP.thy` next to the generated theory in `:local_dir`;
    * `{:error, {:tptp_parse, message}}` — `isabellize_theory/1` raised
      (the parser is tolerant by design, so this should be rare);
    * everything `prove_lemmas/4` can return.
  """
  @spec prove_tptp(Session.t(), Problem.t(), keyword()) :: result()
  def prove_tptp(session, problem, opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)
    config = Keyword.merge(Session.config(session), opts)
    local_dir = Path.expand(Config.fetch!(:isabelle, :local_dir, config))
    proof_method = Keyword.get(opts, :proof_method, "by auto")
    text = problem |> Problem.to_iodata() |> IO.iodata_to_binary()

    with :ok <- File.mkdir_p(local_dir),
         :ok <- ensure_tptp_theory(local_dir),
         {:ok, isabellized} <- safe_isabellize(text) do
      name = Keyword.get(opts, :theory_name) || derive_name(text)
      body = "unbundle from_TPTP\n\n" <> inject_proof_method(isabellized, proof_method)

      prove_lemmas(session, body, name, Keyword.put(opts, :imports, ~s("TPTP")))
    end
  end

  @impl AtpClient.Backend
  @doc """
  Behaviour entry point: opens a session, runs `prove_tptp/3`, and closes the
  session afterwards, even on error.

  The result's `status` is the weakest link over the isabellized lemmas and
  `details.lemmas` has each lemma's own status.

  > #### THF-only {: .warning}
  >
  > `IsabelleClient.TPTP.isabellize_theory/1` in the currently vendored
  > `:isabelle_elixir` (0.4.1) only recognises `thf(…)` annotated formulae.
  > FOF/CNF input is silently dropped by the isabellizer, so the generated
  > body has no lemmas and the result is `:gave_up` — indistinguishable from
  > an honest failed proof. If you need FOF/CNF today, route through the
  > `SystemOnTPTP`, `StarExec`, or `LocalExec` backends instead.
  """
  @spec query(Problem.t(), keyword()) :: result()
  def query(problem, opts \\ []) do
    NimbleOptions.validate!(opts, @opts_schema)
    with_session(opts, &prove_tptp(&1, problem, opts))
  end

  @spec with_session(keyword(), (Session.t() -> result())) :: result()
  defp with_session(opts, fun) do
    case open_session(opts) do
      {:ok, session} ->
        try do
          fun.(session)
        after
          close_session(session)
        end

      {:error, _} = err ->
        err
    end
  end

  # Weakest-link fold over per-lemma statuses. An empty list is not a
  # "trivially proved" state: it means the isabellizer produced no `lemma`
  # declarations from the input, which is what an unsupported dialect looks
  # like (see the caveat on `query/2`).
  @spec weakest([Verdict.lemma_result()]) :: Tptp.Szs.Ontology.t()
  defp weakest([]), do: :gave_up

  defp weakest(lemmas) do
    Enum.find_value(lemmas, :theorem, fn %{status: status} ->
      if status != :theorem, do: status
    end)
  end

  @spec result(Tptp.Szs.Ontology.t(), map(), map()) :: Result.t()
  defp result(status, payload, details) do
    %Result{
      status: status,
      evidence: {:backend, __MODULE__},
      output: Verdict.text(payload),
      backend: __MODULE__,
      details: details
    }
  end

  defp inject_proof_method(isabellized, proof_method) do
    using = using_clause(axiom_names(isabellized))

    isabellized
    |> String.split(~r/\n\n+/)
    |> Enum.map_join("\n\n", fn item ->
      if String.starts_with?(String.trim_leading(item), "lemma ") do
        String.trim_trailing(item) <> "\n  " <> using <> proof_method
      else
        item
      end
    end)
  end

  # The isabellizer renders TPTP axioms as `axiomatization where <name>: …`.
  # Isabelle does not hand those to a tactic on its own, so without an explicit
  # `using` the goal is attempted against HOL alone and any problem that
  # actually depends on its axioms comes back `gave_up` — silently, since that
  # is also what an honest failure looks like.
  defp axiom_names(isabellized) do
    ~r/^\s*axiomatization\s+where\s+([A-Za-z_][A-Za-z0-9_']*)\s*:/m
    |> Regex.scan(isabellized)
    |> Enum.map(fn [_, name] -> name end)
  end

  defp using_clause([]), do: ""
  defp using_clause(names), do: "using " <> Enum.join(names, " ") <> " "

  defp ensure_tptp_theory(local_dir) do
    dest = Path.join(local_dir, "TPTP.thy")

    if File.exists?(dest) do
      :ok
    else
      case File.write(dest, TPTP.source_text()) do
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
end
