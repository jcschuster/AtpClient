defmodule Mix.Tasks.AtpClient.Systems.Audit do
  @shortdoc "Lists what in the systems snapshot needs attention"

  @moduledoc """
  Prints `AtpClient.SystemOnTptp.Audit`'s attention list for the committed
  snapshot, `priv/system_on_tptp/systems.json`, under
  `priv/system_on_tptp/overrides.json`.

      mix atp_client.systems.audit [--strict] [--previous PATH]

    * `--strict` — exit with status 1 when the list is not empty;
    * `--previous` — the snapshot before this one, for the words seen for the
      first time; without it, that finding is not looked for.
  """

  use Mix.Task

  alias AtpClient.System
  alias AtpClient.SystemOnTptp.Audit
  alias AtpClient.SystemOnTptp.Systems

  @switches [strict: :boolean, previous: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("compile")

    dir = Path.join(File.cwd!(), "priv/system_on_tptp")
    %{systems: systems} = Systems.read_snapshot(Path.join(dir, "systems.json"))
    overrides = System.read_overrides(Path.join(dir, "overrides.json"))
    previous = if path = opts[:previous], do: Systems.read_snapshot(path).systems

    case Audit.findings(systems, overrides, previous) do
      [] ->
        Mix.shell().info("#{length(systems)} systems, nothing requires action")

      lines ->
        Mix.shell().info(Audit.format(lines))
        Mix.shell().info("#{length(lines)} finding(s) require action")
        if opts[:strict], do: exit({:shutdown, 1})
    end
  end
end
