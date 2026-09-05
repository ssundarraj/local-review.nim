#!/usr/bin/env sh

set -eu

if ! command -v busted >/dev/null 2>&1; then
  echo "busted is required to run tests. Install it and re-run ./scripts/test.sh." >&2
  exit 1
fi

if ! command -v nvim >/dev/null 2>&1; then
  echo "nvim is required to run smoke tests. Install it and re-run ./scripts/test.sh." >&2
  exit 1
fi

busted tests/positioning_spec.lua
nvim --headless --clean -u NONE -l tests/lww_smoke.lua
nvim --headless --clean -u NONE -l tests/tombstone_smoke.lua
