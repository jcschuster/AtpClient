defmodule AtpClient.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if AtpClient.Config.fetch(:sotptp, :auto_refresh, true) do
        [{AtpClient.SystemOnTptp.Provers, nil}]
      else
        []
      end

    opts = [strategy: :one_for_one, name: AtpClient.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
