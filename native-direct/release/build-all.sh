#!/bin/bash
# THE build process: every platform from one command.
#   ./build-all.sh            local macOS only
#   ./build-all.sh --remote   + linux/windows/android via GitHub CI (gh),
#                             artifacts downloaded into release/out/
set -euo pipefail
cd "$(dirname "$0")"

echo "=== macOS (local: build, bundle, sign, notarize when NOTARY_PROFILE set) ==="
./build-macos.sh

if [ "${1:-}" = "--remote" ]; then
  echo "=== macOS signed+notarized via Boss-Man CI (the signing secrets live there) ==="
  gh workflow run build-asteroidz-native-macos.yml -R macOS26/Boss-Man || true
  echo "=== linux / windows / android via GitHub Actions ==="
  gh workflow run native-release.yml
  sleep 5
  RUN_ID="$(gh run list --workflow=native-release.yml --limit 1 --json databaseId -q '.[0].databaseId')"
  gh run watch "$RUN_ID" --exit-status || echo "→ some lanes failed (experimental lanes fail soft)"
  gh run download "$RUN_ID" --dir out/ci || true
  echo "✓ artifacts in release/out/ + release/out/ci/"
else
  echo "→ pass --remote for linux/windows/android (requires pushed repos + gh auth)"
fi
ls -la out/ 2>/dev/null
