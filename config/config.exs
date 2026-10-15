import Config

# This project's own builds only; a library's config is not shipped. Library
# defaults live in `AtpClient.Config`.

if config_env() == :test do
  # The tests put the systems they need into `AtpClient.SystemOnTptp.Systems`
  # themselves. A background refresh from tptp.org would replace them whenever
  # it happened to finish, and would cost the shared deployment two requests
  # per test run; the agent holds the shipped snapshot instead.
  config :atp_client, :sotptp, auto_refresh: false
end
