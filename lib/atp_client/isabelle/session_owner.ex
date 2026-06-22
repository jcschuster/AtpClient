defmodule AtpClient.Isabelle.SessionOwner do
  @moduledoc false

  # Private GenServer that owns the link to the underlying
  # `IsabelleClient.Shared` process. The caller invokes `start/1` (not
  # `start_link/1`), so:
  #
  #   * a failed `Shared.start_link/1` inside `init/1` surfaces as
  #     `{:error, reason}` from `GenServer.start/2` without killing the caller;
  #   * a runtime crash in the Shared process is trapped here and translated
  #     into a clean `:stop`, again without killing the caller;
  #   * if the caller dies, the monitor below fires and the owner shuts the
  #     Shared process down through `terminate/2`, preventing an orphaned
  #     server-side session.
  #
  # The Session struct still exposes the Shared pid through `:client` so the
  # internal `prove_*` functions can call `IsabelleClient.Shared` directly
  # without going through the owner on every request.

  use GenServer

  alias IsabelleClient.Shared

  @spec start([{atom(), term()}]) :: GenServer.on_start()
  def start(shared_opts) do
    GenServer.start(__MODULE__, {shared_opts, self()})
  end

  @spec shared_pid(pid()) :: pid()
  def shared_pid(owner), do: GenServer.call(owner, :shared_pid)

  @impl true
  def init({shared_opts, caller}) do
    Process.flag(:trap_exit, true)
    Process.monitor(caller)

    case Shared.start_link(shared_opts) do
      {:ok, shared} -> {:ok, %{shared: shared, caller: caller}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:shared_pid, _from, %{shared: pid} = state), do: {:reply, pid, state}

  @impl true
  def handle_info({:EXIT, pid, reason}, %{shared: pid} = state) do
    {:stop, reason, %{state | shared: nil}}
  end

  def handle_info({:DOWN, _ref, :process, caller, _reason}, %{caller: caller} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, %{shared: nil}), do: :ok
  def terminate(_reason, %{shared: shared}), do: Shared.close(shared)
end
