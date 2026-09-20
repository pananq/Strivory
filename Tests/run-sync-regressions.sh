#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/strivory-sync-regressions.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$test_dir/module-cache" \
  "$repo_dir/Strivory/Models.swift" \
  "$repo_dir/Strivory/WorkoutSync.swift" \
  "$repo_dir/Strivory/CSVImporter.swift" \
  "$repo_dir/Strivory/CloudBackupService.swift" \
  "$repo_dir/Strivory/AppStore.swift" \
  "$repo_dir/Tests/SyncRegressionTests.swift" \
  -o "$test_dir/sync-regressions"
"$test_dir/sync-regressions"
