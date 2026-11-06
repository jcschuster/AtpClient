defmodule AtpClient.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    finch_child = {
      Finch,
      name: AtpClient.TptpFinch,
      pools: %{
        :default => [
          protocols: [:http1],
          conn_max_idle_time: 4_000,
          conn_opts: [
            transport_opts: [
              versions: [:"tlsv1.2"],
              verify: :verify_peer,
              cacerts: :public_key.cacerts_get()
            ]
          ]
        ]
      }
    }

    # Systems starts from the shipped snapshot; under `auto_refresh: true` it
    # refreshes in a task of AtpClient.TaskSupervisor.
    children = [
      finch_child,
      {Task.Supervisor, name: AtpClient.TaskSupervisor},
      {AtpClient.SystemOnTptp.Systems, nil}
    ]

    opts = [strategy: :one_for_one, name: AtpClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
