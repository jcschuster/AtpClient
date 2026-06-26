exclude = [:local_prover, :isabelle_server]

# Several tests build `#!/bin/sh` scripts as fake provers and rely on
# POSIX `kill -KILL` to inspect process death — neither is available on
# Windows. Skip the tagged tests there.
exclude =
  case :os.type() do
    {:win32, _} -> [:posix_shell | exclude]
    _ -> exclude
  end

ExUnit.start(exclude: exclude)
