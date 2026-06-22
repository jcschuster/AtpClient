defmodule AtpClient.Config do
  @moduledoc """
  Resolves configuration for each backend by merging (in increasing precedence):

    1. Library defaults declared in this module under `@defaults`.
    2. Application configuration under the `:atp_client` OTP app.
    3. Per-call options passed as a `Keyword.t()`.

  Defaults are merged *per key*, so a partial `config :atp_client, :sotptp, …`
  in `config.exs` only overrides the keys it names; it cannot accidentally
  clobber `:url` and leave the library with no endpoint.

  ## Example

  In `config/config.exs`:

      config :atp_client, :starexec,
        base_url: "https://starexec.example.org/starexec",
        username: System.get_env("STAREXEC_USER"),
        password: System.get_env("STAREXEC_PASS")

      config :atp_client, :isabelle,
        host: "isabelle.example.org",
        port: 9999,
        password: System.get_env("ISABELLE_PASSWORD"),
        local_dir: "/shared/problems",
        isabelle_dir: "/shared/problems",
        session: "HOL"

  Any setting may be overridden per call. For instance,

      AtpClient.Isabelle.query(theory, "Example", session: "Main")

  forces the `Main` session for that single query regardless of what is set
  in `config.exs`.
  """

  @type backend :: :sotptp | :starexec | :isabelle | :local_exec

  # Library defaults, merged in `get/2` *underneath* `Application.get_env/2`.
  # Single source of truth — the `:env` block in `mix.exs` used to install
  # these into the OTP Application env at load time, but per-key user config
  # would then replace the whole keyword list and silently drop the defaults
  # the user did not explicitly re-set. The merge here is unconditional, so
  # a partial `config :atp_client, :sotptp, default_time_limit_sec: 10` no
  # longer wipes out `:url`.
  @defaults [
    sotptp: [
      url: "https://tptp.org/cgi-bin/SystemOnTPTPFormReply",
      auto_refresh: true,
      refresh_timeout_ms: 15_000,
      default_time_limit_sec: 5
    ],
    starexec: [
      request_timeout_ms: 30_000,
      poll_interval_ms: 2_000,
      session_init_path: "/starexec/secure/index.jsp",
      login_path: "/starexec/j_security_check",
      logout_path: "/starexec/services/session/logout",
      job_info_path: "/starexec/services/details/job",
      job_output_path: "/starexec/secure/download",
      create_job_path: "/starexec/secure/add/job",
      delete_job_path: "/starexec/services/delete/job",
      upload_benchmarks_path: "/starexec/secure/upload/benchmarks",
      list_space_benchmarks_path: "/starexec/services/job/{space_id}/allbench/pagination/",
      benchmark_type: 1,
      queue_id: 1,
      cpu_timeout_s: 60
    ],
    isabelle: [
      host: "127.0.0.1",
      port: 9999,
      session: "HOL",
      session_start_timeout_ms: 120_000,
      use_theories_timeout_ms: 120_000
    ],
    local_exec: [
      args: [],
      cpu_timeout_s: 60,
      wall_timeout_ms: nil
    ]
  ]

  @doc """
  Returns the library defaults that `get/2` layers underneath the
  Application env. Exposed mainly so tests and tooling can inspect what
  ships out of the box without parsing `mix.exs`.
  """
  @spec defaults() :: keyword()
  def defaults, do: @defaults

  @doc """
  Returns the fully resolved settings for the given backend as a keyword list.
  """
  @spec get(backend()) :: keyword()
  @spec get(backend(), keyword()) :: keyword()
  def get(backend, opts \\ []) when backend in [:sotptp, :starexec, :isabelle, :local_exec] do
    defaults = Keyword.get(@defaults, backend, [])
    from_env = Application.get_env(:atp_client, backend, [])

    defaults
    |> Keyword.merge(from_env)
    |> Keyword.merge(opts)
    |> post_process(backend)
  end

  @doc """
  Returns the value of `key` from the resolved settings for `backend`, falling
  back to the given `default` if unset or set to `nil`.
  """
  @spec fetch(backend(), atom(), any(), keyword()) :: any()
  def fetch(backend, key, default, opts \\ []) do
    case Keyword.get(get(backend, opts), key) do
      nil -> default
      value -> value
    end
  end

  @doc """
  Returns the value of `key` from the resolved settings for `backend`, raising
  a descriptive `ArgumentError` if unset or `nil`.

  Use this for settings that have no sensible default (for example
  `:base_url`, `:password`, `:local_dir`).
  """
  @spec fetch!(backend(), atom(), keyword()) :: any()
  def fetch!(backend, key, opts \\ []) do
    case Keyword.get(get(backend, opts), key) do
      nil -> raise_missing(backend, key)
      value -> value
    end
  end

  # Backend-specific normalization. Currently only Isabelle needs any.
  defp post_process(cfg, :isabelle) do
    # If `isabelle_dir` is unset, default it to `local_dir`. The two differ
    # only when the BEAM node and the Isabelle server see the shared directory
    # under different paths (e.g. when one runs in a container).
    case {Keyword.get(cfg, :local_dir), Keyword.get(cfg, :isabelle_dir)} do
      {local, nil} when is_binary(local) -> Keyword.put(cfg, :isabelle_dir, local)
      _ -> cfg
    end
  end

  defp post_process(cfg, _backend), do: cfg

  @spec raise_missing(backend(), atom()) :: no_return()
  defp raise_missing(backend, key) do
    raise ArgumentError, """
    AtpClient: missing required setting `#{inspect(key)}` for backend `#{inspect(backend)}`.

    Set it in your application config:

        config :atp_client, #{inspect(backend)},
          #{key}: ...

    or pass it explicitly as an option to the call:

        AtpClient.<function>(..., #{key}: ...)
    """
  end
end
