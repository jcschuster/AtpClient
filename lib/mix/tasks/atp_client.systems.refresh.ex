defmodule Mix.Tasks.AtpClient.Systems.Refresh do
  @shortdoc "Regenerates the SystemOnTPTP systems snapshot and SYSTEMS.md"

  @moduledoc """
  Fetches the SystemInfo report from SystemOnTPTP and writes
  `priv/system_on_tptp/systems.json` and `priv/system_on_tptp/SYSTEMS.md`.

      mix atp_client.systems.refresh [--url URL] [--delta-file PATH]

    * `--url` — the endpoint to query (default the configured `:url`);
    * `--delta-file` — also write the one-line summary of what changed, as the
      nightly workflow titles its pull request with it.

  The summary is printed last either way.
  """

  use Mix.Task

  alias AtpClient.System
  alias AtpClient.SystemOnTptp.SystemInfo
  alias AtpClient.SystemOnTptp.Systems

  @switches [url: :string, delta_file: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)
    start()

    url = opts[:url] || AtpClient.Config.fetch!(:sotptp, :url, [])
    json = Path.join(dir(), "systems.json")
    before = Systems.read_snapshot(json)

    case SystemInfo.fetch(url: url, refresh_timeout_ms: 300_000) do
      {:ok, [_ | _] = systems, warnings} ->
        Enum.each(warnings, &Mix.shell().info("warning: #{inspect(&1)}"))
        state = %{systems: systems, generated_at: DateTime.utc_now(:second), source: url}
        File.mkdir_p!(dir())
        File.write!(json, [Systems.encode_snapshot(state), "\n"])
        File.write!(Path.join(dir(), "SYSTEMS.md"), Systems.markdown(state, overrides()))

        delta = "systems: " <> Systems.delta(before.systems, systems)
        if path = opts[:delta_file], do: File.write!(path, delta <> "\n")
        Mix.shell().info(delta)

      {:ok, [], _warnings} ->
        Mix.raise("the report lists no systems")

      {:error, reason} ->
        Mix.raise("refresh failed: #{inspect(reason)}")
    end
  end

  defp dir, do: Path.join(File.cwd!(), "priv/system_on_tptp")
  defp overrides, do: System.read_overrides(Path.join(dir(), "overrides.json"))

  # The HTTP pool, without the background refresh of the agent.
  defp start do
    Application.put_env(
      :atp_client,
      :sotptp,
      Keyword.put(Application.get_env(:atp_client, :sotptp, []), :auto_refresh, false)
    )

    Mix.Task.run("app.start")
  end
end
