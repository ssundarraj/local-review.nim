#!/usr/bin/env sh

set -eu

LUALS_BIN="${LUALS_BIN:-$HOME/.local/share/nvim/mason/bin/lua-language-server}"

if [ ! -x "$LUALS_BIN" ]; then
  echo "lua-language-server not found at $LUALS_BIN" >&2
  exit 1
fi

VIMRUNTIME="${VIMRUNTIME:-$(nvim --clean --headless '+lua io.write(vim.env.VIMRUNTIME)' +qa)}"
export VIMRUNTIME

exec "$LUALS_BIN" --check=. --configpath=.luarc.json --check_format=pretty --checklevel=Warning
