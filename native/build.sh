#!/bin/bash
# Convenience: build the wasmtime host from the repo root.
# The real build script lives in asteroidz-web/Packages/SuperBox64Kit/native/.
set -euo pipefail
REPO="$(cd "$(dirname "$0")"/.. && pwd)"
exec "$REPO/asteroidz-web/Packages/SuperBox64Kit/native/build-wasmtime-host.sh" "$@"