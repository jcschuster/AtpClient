# AtpMcp configuration for the claude-env container (`claude-env init
# atpclient`); the entrypoint exports ATP_MCP_CONFIG pointing here. Plain
# `Config`, read once when the server starts; see the AtpMcp README.
import Config

# SystemOnTPTP: library defaults (tptp.org, latest E).

# LocalExec: E built into the image. `eprover-ho` and `vampire` are on PATH
# as well; switch `binary`/`args` to use one of them by default.
config :atp_client, :local_exec,
  binary: "eprover",
  args: ["--auto", "--tstp-format", "--cpu-limit=30"],
  cpu_timeout_s: 30

# StarExec: the sidecar claude-env starts. `space_id` and `solver_cfg_id`
# depend on what has been uploaded to the instance; set them here once known.
config :atp_client, :starexec,
  base_url: System.get_env("STAREXEC_URL", "http://localhost:7827"),
  username: System.get_env("STAREXEC_USER", "admin"),
  password: System.get_env("STAREXEC_PASS", "admin")

# Isabelle: AtpMcp starts its own resident server (`isabelle` is on PATH).
