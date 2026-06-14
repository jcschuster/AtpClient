#!/usr/bin/env bash
# Build the E theorem prover from source and install the resulting `eprover`
# binary into `priv/bin/` for use with `AtpClient.LocalExec`.
#
# Usage:
#     scripts/build_eprover.sh                # builds the pinned tag
#     E_TAG=E-3.2.7 scripts/build_eprover.sh  # override the pinned tag
#
# Requires: git, make, a C compiler (cc / gcc / clang).
#
# The build directory is created under `tmp/` and removed on success. Re-run
# the script to rebuild; it is idempotent.

set -euo pipefail

E_REPO="${E_REPO:-https://github.com/eprover/eprover.git}"
E_TAG="${E_TAG:-E-3.2.7}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${repo_root}/tmp/eprover-build"
install_dir="${repo_root}/priv/bin"
target="${install_dir}/eprover"

echo ">>> building E ${E_TAG} from ${E_REPO}"
echo ">>> build dir:   ${build_dir}"
echo ">>> install to:  ${target}"

for tool in git make cc; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        # `cc` is sometimes provided as `gcc` only.
        if [ "${tool}" = "cc" ] && command -v gcc >/dev/null 2>&1; then
            continue
        fi
        echo "error: required tool '${tool}' not found on PATH" >&2
        exit 1
    fi
done

rm -rf "${build_dir}"
mkdir -p "${build_dir}"
git clone --depth 1 --branch "${E_TAG}" "${E_REPO}" "${build_dir}"

cd "${build_dir}"
./configure
make

mkdir -p "${install_dir}"
cp PROVER/eprover "${target}"

cd "${repo_root}"
rm -rf "${build_dir}"

echo ">>> done. Verify with:"
echo "    ${target} --version"
echo ">>> point AtpClient.LocalExec at it via:"
echo "    config :atp_client, :local_exec, binary: \"${target}\""
