#!/bin/bash
# 使い方: tests/ui/run.sh <A|B|C> [user]   (Playwright 1.56 / Chromium を docker で実行)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
mkdir -p "$ROOT/docs/evidence"
PW=$(sudo grep '^ADMIN_PASSWORD=' "$ROOT/.env" | cut -d= -f2)
$DOCKER run --rm --network host -e ADMIN_PASSWORD="$PW" -e OUT=/evidence \
  -v "$ROOT/tests/ui":/t -v "$ROOT/docs/evidence":/evidence -w /t \
  mcr.microsoft.com/playwright:v1.56.0-noble \
  sh -c 'npm install --no-audit --no-fund >/dev/null 2>&1; node ui-test.mjs "$@"' sh "$@"
