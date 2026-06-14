defmodule AtpClient.Config do
  @moduledoc """
  Resolves configuration for each backend by merging (in increasing precedence):

    1. Library defaults declared in `mix.exs` under the `:env` key.
    2. Application configuration under the `:atp_client` OTP app.
    3. Per-call options passed as a `Keyword.t()`.

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

      AtpClient.Isabelle.query(theory, session: "Main")

  forces the `Main` session for that single query regardless of what is set
  in `config.exs`.
  """

  @type backend :: :sotptp | :starexec | :isabelle | :local_exec

  @doc """
  Returns the fully resolved settings for the given backend as a keyword list.
  """
  @spec get(backend()) :: keyword()
  @spec get(backend(), keyword()) :: keyword()
  def get(backend, opts \\ []) when backend in [:sotptp, :starexec, :isabelle, :local_exec] do
    from_env = Application.get_env(:atp_client, backend, [])

    from_env
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
